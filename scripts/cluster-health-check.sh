#!/usr/bin/env bash
#
# cluster-health-check.sh - point-in-time health report for the gentoo k3s cluster.
#
# Runs from an admin workstation with SSH access to the nodes (the local kubectl
# context is not wired to this cluster - see CLAUDE.md). Fetches all Kubernetes-level
# state through one SSH session to the control-plane node, and OS-level metrics
# (disk, memory, CPU load, temperature, k3s service state) through one SSH session
# per node, then reports PASS/WARN/FAIL/INFO for each check plus a final summary.
#
# Usage:   ./cluster-health-check.sh [--only nodes,pods,storage,...] [--no-color] [--quiet]
# Config (env vars): CONTROL_NODE WORKER_NODES SSH_USER SSH_KEY
#                     DISK_WARN_PCT DISK_CRIT_PCT MEM_WARN_PCT MEM_CRIT_PCT
#                     LOAD_WARN_RATIO LOAD_CRIT_RATIO TEMP_WARN_C TEMP_CRIT_C
#                     CERT_EXPIRY_WARN_DAYS RECENT_RESTART_WINDOW_SEC EVENT_WINDOW_MIN
#
# Exit codes: 0 = all checks passed, 1 = warnings only, 2 = at least one failure
#             (or a node/API the script couldn't reach at all)

set -uo pipefail

CONTROL_NODE="${CONTROL_NODE:-cachyos}"
WORKER_NODES="${WORKER_NODES:-tux}"
SSH_USER="${SSH_USER:-slowking}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-i "$SSH_KEY" -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
DISK_CRIT_PCT="${DISK_CRIT_PCT:-90}"
MEM_WARN_PCT="${MEM_WARN_PCT:-85}"
MEM_CRIT_PCT="${MEM_CRIT_PCT:-95}"
LOAD_WARN_RATIO="${LOAD_WARN_RATIO:-1.0}"
LOAD_CRIT_RATIO="${LOAD_CRIT_RATIO:-1.5}"
TEMP_WARN_C="${TEMP_WARN_C:-75}"
TEMP_CRIT_C="${TEMP_CRIT_C:-90}"
CERT_EXPIRY_WARN_DAYS="${CERT_EXPIRY_WARN_DAYS:-21}"
RECENT_RESTART_WINDOW_SEC="${RECENT_RESTART_WINDOW_SEC:-3600}"
EVENT_WINDOW_MIN="${EVENT_WINDOW_MIN:-60}"

NO_COLOR=0
QUIET=0
ONLY_FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-color) NO_COLOR=1; shift ;;
    --quiet|-q) QUIET=1; shift ;;
    --only) ONLY_FILTER="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [ -t 1 ] && [ "$NO_COLOR" -eq 0 ]; then
  C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_GRN='\033[0;32m'; C_BLU='\033[0;34m'; C_DIM='\033[2m'; C_RST='\033[0m'
else
  C_RED=''; C_YEL=''; C_GRN=''; C_BLU=''; C_DIM=''; C_RST=''
fi

PASS_N=0; WARN_N=0; FAIL_N=0; INFO_N=0
declare -a ISSUES=()

should_run() {
  [ -z "$ONLY_FILTER" ] && return 0
  case ",$ONLY_FILTER," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

section() {
  [ "$QUIET" -eq 1 ] && return 0
  printf '\n%b== %s ==%b\n' "$C_BLU" "$1" "$C_RST"
}

record() {
  local level="$1" ctx="$2" msg="$3"
  case "$level" in
    PASS) PASS_N=$((PASS_N+1)); [ "$QUIET" -eq 1 ] && return 0
          printf '%b  [PASS]%b %-22s %s\n' "$C_GRN" "$C_RST" "$ctx" "$msg" ;;
    WARN) WARN_N=$((WARN_N+1)); ISSUES+=("WARN  $ctx: $msg")
          printf '%b  [WARN]%b %-22s %s\n' "$C_YEL" "$C_RST" "$ctx" "$msg" ;;
    FAIL) FAIL_N=$((FAIL_N+1)); ISSUES+=("FAIL  $ctx: $msg")
          printf '%b  [FAIL]%b %-22s %s\n' "$C_RED" "$C_RST" "$ctx" "$msg" ;;
    INFO) INFO_N=$((INFO_N+1)); [ "$QUIET" -eq 1 ] && return 0
          printf '%b  [INFO]%b %-22s %s\n' "$C_DIM" "$C_RST" "$ctx" "$msg" ;;
  esac
}

ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

epoch_from_iso() { date -d "$1" +%s 2>/dev/null; }

for tool in ssh jq awk date; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 64; }
done

# ---------------------------------------------------------------------------
# Fetch phase: one SSH session to the control node bundles every kubectl call
# plus its own OS metrics; one SSH session per worker node for OS metrics only.
# ---------------------------------------------------------------------------

K8S_FETCH_CMDS='
echo "===BEGIN:nodes_json==="; kubectl get nodes -o json 2>&1; echo "===END:nodes_json==="
echo "===BEGIN:pods_json==="; kubectl get pods -A -o json 2>&1; echo "===END:pods_json==="
echo "===BEGIN:pv_json==="; kubectl get pv -o json 2>&1; echo "===END:pv_json==="
echo "===BEGIN:pvc_json==="; kubectl get pvc -A -o json 2>&1; echo "===END:pvc_json==="
echo "===BEGIN:top_nodes==="; kubectl top nodes --no-headers 2>&1; echo "===END:top_nodes==="
echo "===BEGIN:livez==="; kubectl get --raw '"'"'/livez?verbose'"'"' 2>&1; echo "===END:livez==="
echo "===BEGIN:readyz==="; kubectl get --raw '"'"'/readyz?verbose'"'"' 2>&1; echo "===END:readyz==="
echo "===BEGIN:argo_apps_json==="; kubectl get applications.argoproj.io -n argocd -o json 2>&1; echo "===END:argo_apps_json==="
echo "===BEGIN:longhorn_vol_json==="; kubectl get volumes.longhorn.io -n longhorn-system -o json 2>&1; echo "===END:longhorn_vol_json==="
echo "===BEGIN:longhorn_node_json==="; kubectl get nodes.longhorn.io -n longhorn-system -o json 2>&1; echo "===END:longhorn_node_json==="
echo "===BEGIN:certs_json==="; kubectl get certificates.cert-manager.io -A -o json 2>&1; echo "===END:certs_json==="
echo "===BEGIN:deploy_json==="; kubectl get deployments -A -o json 2>&1; echo "===END:deploy_json==="
echo "===BEGIN:sts_json==="; kubectl get statefulsets -A -o json 2>&1; echo "===END:sts_json==="
echo "===BEGIN:ds_json==="; kubectl get daemonsets -A -o json 2>&1; echo "===END:ds_json==="
echo "===BEGIN:events_json==="; kubectl get events -A -o json --field-selector type=Warning 2>&1; echo "===END:events_json==="
echo "===BEGIN:falco_logs==="; for p in $(kubectl get pods -n falco -l app.kubernetes.io/name=falco -o name 2>/dev/null); do kubectl logs -n falco "$p" --since=1h --all-containers 2>/dev/null; done; echo "===END:falco_logs==="
'

OS_FETCH_CMDS='
echo "===BEGIN:hostname==="; hostname; echo "===END:hostname==="
echo "===BEGIN:uptime==="; uptime; echo "===END:uptime==="
echo "===BEGIN:nproc==="; nproc; echo "===END:nproc==="
echo "===BEGIN:df==="; df -P / /var/lib/rancher /var/lib/longhorn 2>/dev/null; echo "===END:df==="
echo "===BEGIN:free==="; free -m; echo "===END:free==="
echo "===BEGIN:k3s_status==="; systemctl is-active k3s 2>/dev/null || echo unknown; echo "===END:k3s_status==="
echo "===BEGIN:temp==="
found=0
for z in /sys/class/thermal/thermal_zone*/temp; do
  [ -r "$z" ] || continue
  found=1
  cat "$z"
done
if [ "$found" -eq 0 ] && command -v sensors >/dev/null 2>&1; then
  sensors -A 2>/dev/null
fi
echo "===END:temp==="
echo "===BEGIN:kernel==="; uname -r; echo "===END:kernel==="
'

declare -A DATA=()
declare -A NODE_UNREACHABLE=()

extract_section() {
  local blob="$1" name="$2"
  awk -v s="===BEGIN:${name}===" -v e="===END:${name}===" '
    $0==s{flag=1; next} $0==e{flag=0} flag{print}
  ' <<<"$blob"
}

is_json() { jq empty >/dev/null 2>&1 <<<"$1"; }

fetch_control() {
  local blob
  if ! blob=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CONTROL_NODE}" bash -s <<<"${K8S_FETCH_CMDS}${OS_FETCH_CMDS}" 2>&1); then
    echo "CRITICAL: cannot reach control-plane node ${CONTROL_NODE} via SSH (${SSH_USER}@${CONTROL_NODE}) - no cluster checks are possible." >&2
    echo "$blob" >&2
    exit 2
  fi
  for name in nodes_json pods_json pv_json pvc_json top_nodes livez readyz \
              argo_apps_json longhorn_vol_json longhorn_node_json certs_json \
              deploy_json sts_json ds_json events_json falco_logs; do
    DATA["ctl:$name"]=$(extract_section "$blob" "$name")
  done
  for name in hostname uptime nproc df free k3s_status temp kernel; do
    DATA["node:${CONTROL_NODE}:$name"]=$(extract_section "$blob" "$name")
  done
}

fetch_worker() {
  local node="$1" blob
  if ! blob=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" bash -s <<<"${OS_FETCH_CMDS}" 2>&1); then
    NODE_UNREACHABLE["$node"]=1
    return
  fi
  for name in hostname uptime nproc df free k3s_status temp kernel; do
    DATA["node:${node}:$name"]=$(extract_section "$blob" "$name")
  done
}

fetch_control
for w in $WORKER_NODES; do
  [ "$w" = "$CONTROL_NODE" ] && continue
  fetch_worker "$w"
done

ALL_NODES="$CONTROL_NODE $WORKER_NODES"

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_node_status() {
  should_run nodes || return 0
  section "Node status"
  local j="${DATA[ctl:nodes_json]}"
  if ! is_json "$j"; then record FAIL "nodes" "could not list nodes: $j"; return; fi
  while IFS=$'\t' read -r name ready mem disk pid unsched kver; do
    [ -z "$name" ] && continue
    if [ "$ready" != "True" ]; then
      record FAIL "node/$name" "NotReady (Ready=$ready)"
    elif [ "$mem" = "True" ] || [ "$disk" = "True" ] || [ "$pid" = "True" ]; then
      record FAIL "node/$name" "pressure condition set (mem=$mem disk=$disk pid=$pid)"
    elif [ "$unsched" = "true" ]; then
      record WARN "node/$name" "cordoned (unschedulable), kubelet $kver"
    else
      record PASS "node/$name" "Ready, kubelet $kver"
    fi
  done < <(jq -r '
    .items[] | [
      .metadata.name,
      ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown"),
      ((.status.conditions[]? | select(.type=="MemoryPressure") | .status) // "Unknown"),
      ((.status.conditions[]? | select(.type=="DiskPressure") | .status) // "Unknown"),
      ((.status.conditions[]? | select(.type=="PIDPressure") | .status) // "Unknown"),
      (.spec.unschedulable // false | tostring),
      .status.nodeInfo.kubeletVersion
    ] | @tsv' <<<"$j")
}

check_api_health() {
  should_run api || return 0
  section "API server / kubelet"
  local livez="${DATA[ctl:livez]}" readyz="${DATA[ctl:readyz]}"
  if grep -q 'livez check passed' <<<"$livez"; then
    record PASS "livez" "all subsystems ok"
  else
    record FAIL "livez" "$(grep -i failed <<<"$livez" | tr '\n' ';' | sed 's/;$//' || echo "$livez" | tail -1)"
  fi
  if grep -q 'readyz check passed' <<<"$readyz"; then
    record PASS "readyz" "all subsystems ok"
  else
    record FAIL "readyz" "$(grep -i failed <<<"$readyz" | tr '\n' ';' | sed 's/;$//' || echo "$readyz" | tail -1)"
  fi
  for node in $ALL_NODES; do
    local st="${DATA[node:${node}:k3s_status]:-}"
    if [ -n "${NODE_UNREACHABLE[$node]:-}" ]; then continue; fi
    if [ "$st" = "active" ]; then
      record PASS "k3s@$node" "systemd unit active"
    else
      record FAIL "k3s@$node" "systemd unit state: ${st:-unknown}"
    fi
  done
}

check_node_resources() {
  should_run resources || return 0
  section "Cluster-reported node resource usage (kubectl top)"
  local t="${DATA[ctl:top_nodes]}"
  if [ -z "$t" ] || grep -qi 'error\|not found\|no such' <<<"$t"; then
    record WARN "metrics-server" "kubectl top nodes unavailable - skipping"
    return
  fi
  while read -r name _cpu cpupct _mem mempct; do
    [ -z "$name" ] && continue
    cpupct="${cpupct%\%}"; mempct="${mempct%\%}"
    if ge "$mempct" "$MEM_CRIT_PCT"; then
      record FAIL "node/$name" "memory ${mempct}% (>= ${MEM_CRIT_PCT}%), cpu ${cpupct}%"
    elif ge "$mempct" "$MEM_WARN_PCT"; then
      record WARN "node/$name" "memory ${mempct}% (>= ${MEM_WARN_PCT}%), cpu ${cpupct}%"
    else
      record PASS "node/$name" "cpu ${cpupct}%, memory ${mempct}%"
    fi
  done <<<"$t"
}

check_node_os_metrics() {
  should_run os || return 0
  section "Node OS metrics (disk, memory, load, temperature)"
  for node in $ALL_NODES; do
    if [ -n "${NODE_UNREACHABLE[$node]:-}" ]; then
      record WARN "node/$node" "unreachable via SSH - skipping OS-level checks (cluster-wide checks unaffected)"
      continue
    fi

    local dfout seen_dev
    dfout="${DATA[node:${node}:df]}"
    seen_dev=""
    while read -r fs size used avail pct mnt; do
      [ "$fs" = "Filesystem" ] && continue
      [ -z "$fs" ] && continue
      pct="${pct%\%}"
      case " $seen_dev " in *" $fs "*) continue ;; esac
      seen_dev="$seen_dev $fs"
      if ge "$pct" "$DISK_CRIT_PCT"; then
        record FAIL "disk/$node" "$mnt at ${pct}% ($fs)"
      elif ge "$pct" "$DISK_WARN_PCT"; then
        record WARN "disk/$node" "$mnt at ${pct}% ($fs)"
      else
        record PASS "disk/$node" "$mnt at ${pct}% ($fs)"
      fi
    done <<<"$dfout"

    local freeout memtotal memused mempct
    freeout="${DATA[node:${node}:free]}"
    memtotal=$(awk '/^Mem:/{print $2}' <<<"$freeout")
    memused=$(awk '/^Mem:/{print $3}' <<<"$freeout")
    if [ -n "${memtotal:-}" ] && [ "$memtotal" -gt 0 ] 2>/dev/null; then
      mempct=$(awk -v u="$memused" -v t="$memtotal" 'BEGIN{printf "%.0f", (u/t)*100}')
      if ge "$mempct" "$MEM_CRIT_PCT"; then
        record FAIL "memory/$node" "${mempct}% used (${memused}Mi / ${memtotal}Mi)"
      elif ge "$mempct" "$MEM_WARN_PCT"; then
        record WARN "memory/$node" "${mempct}% used (${memused}Mi / ${memtotal}Mi)"
      else
        record PASS "memory/$node" "${mempct}% used (${memused}Mi / ${memtotal}Mi)"
      fi
    else
      record WARN "memory/$node" "could not parse 'free -m' output"
    fi

    local nproc load1 ratio
    nproc="${DATA[node:${node}:nproc]}"
    load1=$(awk -F'load average: ' '{print $2}' <<<"${DATA[node:${node}:uptime]}" | awk -F', ' '{print $1}')
    if [ -n "${nproc:-}" ] && [ -n "${load1:-}" ]; then
      ratio=$(awk -v l="$load1" -v n="$nproc" 'BEGIN{printf "%.2f", l/n}')
      if ge "$ratio" "$LOAD_CRIT_RATIO"; then
        record FAIL "load/$node" "load1=$load1 on ${nproc} cores (ratio ${ratio})"
      elif ge "$ratio" "$LOAD_WARN_RATIO"; then
        record WARN "load/$node" "load1=$load1 on ${nproc} cores (ratio ${ratio})"
      else
        record PASS "load/$node" "load1=$load1 on ${nproc} cores (ratio ${ratio})"
      fi
    else
      record WARN "load/$node" "could not parse uptime/nproc output"
    fi

    local tempraw maxmdeg maxc
    tempraw="${DATA[node:${node}:temp]}"
    maxmdeg=$(grep -E '^[0-9]+$' <<<"$tempraw" | sort -n | tail -1)
    if [ -n "${maxmdeg:-}" ]; then
      maxc=$(awk -v m="$maxmdeg" 'BEGIN{printf "%.1f", m/1000}')
      if ge "$maxc" "$TEMP_CRIT_C"; then
        record FAIL "temp/$node" "hottest thermal zone ${maxc}C (>= ${TEMP_CRIT_C}C)"
      elif ge "$maxc" "$TEMP_WARN_C"; then
        record WARN "temp/$node" "hottest thermal zone ${maxc}C (>= ${TEMP_WARN_C}C)"
      else
        record PASS "temp/$node" "hottest thermal zone ${maxc}C"
      fi
    else
      record INFO "temp/$node" "no readable thermal zones / sensors found"
    fi

    local up
    up=$(awk -F'( |,) *up *' '{print $2}' <<<"${DATA[node:${node}:uptime]}" | awk -F',  *[0-9]+ user' '{print $1}')
    record INFO "uptime/$node" "up ${up:-unknown}, kernel $(cat <<<"${DATA[node:${node}:kernel]}")"
  done
}

check_pods() {
  should_run pods || return 0
  section "Pod health"
  local j="${DATA[ctl:pods_json]}"
  if ! is_json "$j"; then record FAIL "pods" "could not list pods: $j"; return; fi

  local total running succeeded other
  total=$(jq '.items | length' <<<"$j")
  running=$(jq '[.items[] | select(.status.phase=="Running")] | length' <<<"$j")
  succeeded=$(jq '[.items[] | select(.status.phase=="Succeeded")] | length' <<<"$j")
  other=$((total - running - succeeded))
  record INFO "pods" "$total total: $running Running, $succeeded Succeeded, $other other"

  while IFS=$'\t' read -r ns name phase; do
    [ -z "$ns" ] && continue
    record FAIL "pod/$ns/$name" "phase=$phase"
  done < <(jq -r '.items[] | select(.status.phase!="Running" and .status.phase!="Succeeded") | [.metadata.namespace,.metadata.name,.status.phase] | @tsv' <<<"$j")

  while IFS=$'\t' read -r ns name cname reason; do
    [ -z "$ns" ] && continue
    record FAIL "pod/$ns/$name" "container $cname waiting: $reason"
  done < <(jq -r '
    .items[] as $p | (($p.status.containerStatuses // []) + ($p.status.initContainerStatuses // []))[] as $c |
    select($c.state.waiting.reason? and ($c.state.waiting.reason | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|RunContainerError"))) |
    [$p.metadata.namespace, $p.metadata.name, $c.name, $c.state.waiting.reason] | @tsv' <<<"$j")

  local now; now=$(date -u +%s)
  local -A bucket_count=()
  while IFS=$'\t' read -r ns name cname restarts reason exitcode finishedat; do
    [ -z "$ns" ] && continue
    [ "$restarts" = "0" ] && continue
    local ctx="pod/$ns/$name:$cname"
    if [ "$reason" = "Completed" ] && [ "$exitcode" = "0" ]; then
      record INFO "$ctx" "$restarts restart(s), last exit 0/Completed (expected recycle pattern)"
      continue
    fi
    local age=999999
    if [ "$finishedat" != "-" ] && [ -n "$finishedat" ]; then
      local ep; ep=$(epoch_from_iso "$finishedat")
      [ -n "$ep" ] && age=$((now - ep))
    fi
    if [ "$age" -lt "$RECENT_RESTART_WINDOW_SEC" ]; then
      record FAIL "$ctx" "$restarts restart(s), last exit reason=$reason code=$exitcode ${age}s ago"
      continue
    fi
    # A single Unknown/255 exit is containerd/kubelet's signature for "this
    # container was killed by something outside itself" (node reboot, k3s
    # restart) rather than an app crash. When dozens of unrelated pods all
    # show exactly that at the same age, it's one shared event, not dozens of
    # independent problems - fold them into one line per ~6h time bucket
    # instead of flagging every pod individually. Multiple restarts, or any
    # other exit reason, still get their own line below.
    if [ "$restarts" = "1" ] && [ "$reason" = "Unknown" ]; then
      local bucket=$(( (age / 3600 / 6) * 6 ))
      bucket_count["$bucket"]=$(( ${bucket_count["$bucket"]:-0} + 1 ))
      continue
    fi
    record WARN "$ctx" "$restarts restart(s) historically, last exit reason=$reason code=$exitcode (stable since, $((age/3600))h ago)"
  done < <(jq -r '
    .items[] as $p | ($p.status.containerStatuses // [])[] as $c |
    select($c.restartCount > 0) |
    [$p.metadata.namespace, $p.metadata.name, $c.name, ($c.restartCount|tostring),
     ($c.lastState.terminated.reason // "-"), ($c.lastState.terminated.exitCode // "-" | tostring),
     ($c.lastState.terminated.finishedAt // "-")] | @tsv' <<<"$j")

  local b
  for b in "${!bucket_count[@]}"; do
    record INFO "pods" "${bucket_count[$b]} container(s) restarted exactly once ~${b}h ago, reason=Unknown/exit 255 - consistent with a node reboot/k3s restart around then, not app-level crashes"
  done
}

check_storage() {
  should_run storage || return 0
  section "Persistent storage (PV/PVC, Longhorn)"
  local pvj="${DATA[ctl:pv_json]}" pvcj="${DATA[ctl:pvc_json]}"

  if is_json "$pvj"; then
    while IFS=$'\t' read -r name phase claimns claimname; do
      [ -z "$name" ] && continue
      case "$phase" in
        Bound) record PASS "pv/$name" "Bound to $claimns/$claimname" ;;
        Available) record INFO "pv/$name" "Available (unclaimed)" ;;
        Released) record WARN "pv/$name" "Released - was $claimns/$claimname, likely orphaned (no PVC rebinds a Released PV); verify before deleting" ;;
        Failed) record FAIL "pv/$name" "Failed (was $claimns/$claimname)" ;;
        *) record WARN "pv/$name" "phase=$phase" ;;
      esac
    done < <(jq -r '.items[] | [.metadata.name, .status.phase, (.spec.claimRef.namespace // "-"), (.spec.claimRef.name // "-")] | @tsv' <<<"$pvj")
  else
    record FAIL "pv" "could not list PVs: $pvj"
  fi

  if is_json "$pvcj"; then
    while IFS=$'\t' read -r ns name phase; do
      [ -z "$ns" ] && continue
      if [ "$phase" = "Bound" ]; then
        record PASS "pvc/$ns/$name" "Bound"
      else
        record FAIL "pvc/$ns/$name" "phase=$phase"
      fi
    done < <(jq -r '.items[] | select(.status.phase!="Bound") | [.metadata.namespace,.metadata.name,.status.phase] | @tsv' <<<"$pvcj")
  fi

  local lvj="${DATA[ctl:longhorn_vol_json]}"
  if is_json "$lvj"; then
    while IFS=$'\t' read -r name robustness state pvc; do
      [ -z "$name" ] && continue
      case "$robustness" in
        healthy) record PASS "longhorn-vol/$name" "healthy, $state ($pvc)" ;;
        degraded) record WARN "longhorn-vol/$name" "degraded, $state ($pvc) - a replica is rebuilding or missing" ;;
        faulted) record FAIL "longhorn-vol/$name" "faulted, $state ($pvc)" ;;
        unknown)
          if [ "$pvc" = "-" ]; then
            record WARN "longhorn-vol/$name" "unknown/$state, no bound PVC - orphaned volume, safe-to-review candidate for cleanup"
          else
            record WARN "longhorn-vol/$name" "unknown/$state ($pvc)"
          fi
          ;;
        *) record WARN "longhorn-vol/$name" "robustness=$robustness state=$state ($pvc)" ;;
      esac
    done < <(jq -r '.items[] | [.metadata.name, .status.robustness, .status.state, (.status.kubernetesStatus.pvcName // "-")] | @tsv' <<<"$lvj")
  else
    record INFO "longhorn-vol" "Longhorn volumes CRD not available - skipping"
  fi

  local lnj="${DATA[ctl:longhorn_node_json]}"
  if is_json "$lnj"; then
    while IFS=$'\t' read -r node disk avail max; do
      [ -z "$node" ] && continue
      [ "$max" = "0" ] || [ -z "$max" ] && continue
      local freepct; freepct=$(awk -v a="$avail" -v m="$max" 'BEGIN{printf "%.0f", (a/m)*100}')
      if [ "$freepct" -le $((100 - DISK_CRIT_PCT)) ]; then
        record FAIL "longhorn-disk/$node" "$disk: ${freepct}% free"
      elif [ "$freepct" -le $((100 - DISK_WARN_PCT)) ]; then
        record WARN "longhorn-disk/$node" "$disk: ${freepct}% free"
      else
        record PASS "longhorn-disk/$node" "$disk: ${freepct}% free"
      fi
    done < <(jq -r '.items[] as $n | $n.metadata.name as $node | ($n.status.diskStatus // {}) | to_entries[] | [$node, .key, (.value.storageAvailable // 0), (.value.storageMaximum // 0)] | @tsv' <<<"$lnj")
  fi
}

check_argocd() {
  should_run argocd || return 0
  section "Argo CD applications"
  local j="${DATA[ctl:argo_apps_json]}"
  if ! is_json "$j"; then record INFO "argocd" "not available - skipping"; return; fi
  while IFS=$'\t' read -r name sync health; do
    [ -z "$name" ] && continue
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      record PASS "app/$name" "Synced/Healthy"
    elif [ "$health" = "Degraded" ] || [ "$health" = "Unknown" ]; then
      record FAIL "app/$name" "sync=$sync health=$health"
    else
      record WARN "app/$name" "sync=$sync health=$health"
    fi
  done < <(jq -r '.items[] | [.metadata.name, .status.sync.status, .status.health.status] | @tsv' <<<"$j")
}

check_controllers() {
  should_run controllers || return 0
  section "Controller rollout status (Deployments/StatefulSets/DaemonSets)"
  local dj="${DATA[ctl:deploy_json]}" sj="${DATA[ctl:sts_json]}" jj="${DATA[ctl:ds_json]}"
  if is_json "$dj"; then
    while IFS=$'\t' read -r ns name ready desired; do
      [ -z "$ns" ] && continue
      [ "$desired" = "0" ] && continue
      if [ "$ready" = "$desired" ]; then
        record PASS "deploy/$ns/$name" "$ready/$desired ready"
      else
        record FAIL "deploy/$ns/$name" "$ready/$desired ready"
      fi
    done < <(jq -r '.items[] | [.metadata.namespace, .metadata.name, (.status.readyReplicas // 0 | tostring), (.spec.replicas // 0 | tostring)] | @tsv' <<<"$dj")
  fi
  if is_json "$sj"; then
    while IFS=$'\t' read -r ns name ready desired; do
      [ -z "$ns" ] && continue
      [ "$desired" = "0" ] && continue
      if [ "$ready" = "$desired" ]; then
        record PASS "sts/$ns/$name" "$ready/$desired ready"
      else
        record FAIL "sts/$ns/$name" "$ready/$desired ready"
      fi
    done < <(jq -r '.items[] | [.metadata.namespace, .metadata.name, (.status.readyReplicas // 0 | tostring), (.spec.replicas // 0 | tostring)] | @tsv' <<<"$sj")
  fi
  if is_json "$jj"; then
    while IFS=$'\t' read -r ns name ready desired; do
      [ -z "$ns" ] && continue
      [ "$desired" = "0" ] && continue
      if [ "$ready" = "$desired" ]; then
        record PASS "ds/$ns/$name" "$ready/$desired ready"
      else
        record FAIL "ds/$ns/$name" "$ready/$desired ready"
      fi
    done < <(jq -r '.items[] | [.metadata.namespace, .metadata.name, (.status.numberReady // 0 | tostring), (.status.desiredNumberScheduled // 0 | tostring)] | @tsv' <<<"$jj")
  fi
}

check_certs() {
  should_run certs || return 0
  section "cert-manager certificates"
  local j="${DATA[ctl:certs_json]}"
  if ! is_json "$j"; then record INFO "certs" "cert-manager Certificates not available - skipping"; return; fi
  local now; now=$(date -u +%s)
  while IFS=$'\t' read -r ns name ready notafter; do
    [ -z "$ns" ] && continue
    if [ "$ready" != "True" ]; then
      record FAIL "cert/$ns/$name" "not Ready"
      continue
    fi
    if [ "$notafter" = "-" ] || [ -z "$notafter" ]; then
      record WARN "cert/$ns/$name" "Ready but no notAfter reported"
      continue
    fi
    local exp; exp=$(epoch_from_iso "$notafter")
    if [ -z "$exp" ]; then record WARN "cert/$ns/$name" "could not parse notAfter=$notafter"; continue; fi
    local days=$(( (exp - now) / 86400 ))
    if [ "$days" -lt 0 ]; then
      record FAIL "cert/$ns/$name" "EXPIRED ${notafter}"
    elif [ "$days" -lt "$CERT_EXPIRY_WARN_DAYS" ]; then
      record WARN "cert/$ns/$name" "expires in ${days}d ($notafter)"
    else
      record PASS "cert/$ns/$name" "expires in ${days}d"
    fi
  done < <(jq -r '.items[] | [.metadata.namespace, .metadata.name, ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown"), (.status.notAfter // "-")] | @tsv' <<<"$j")
}

check_events() {
  should_run events || return 0
  section "Recent Warning events (last ${EVENT_WINDOW_MIN}m)"
  local j="${DATA[ctl:events_json]}"
  if ! is_json "$j"; then record INFO "events" "could not list events"; return; fi
  local now cutoff; now=$(date -u +%s); cutoff=$((EVENT_WINDOW_MIN * 60))
  local count=0
  while IFS=$'\t' read -r ns kind name reason msg ts; do
    [ -z "$ns" ] && continue
    [ "$ts" = "-" ] && continue
    local ep; ep=$(epoch_from_iso "$ts")
    [ -z "$ep" ] && continue
    [ $((now - ep)) -le "$cutoff" ] || continue
    count=$((count+1))
    record WARN "event/$ns/$kind/$name" "$reason: $msg"
  done < <(jq -r '.items[] | [.involvedObject.namespace, .involvedObject.kind, .involvedObject.name, .reason, (.message | gsub("\n";" ") | .[0:120]), (.lastTimestamp // "-")] | @tsv' <<<"$j")
  [ "$count" -eq 0 ] && record PASS "events" "no Warning events in the last ${EVENT_WINDOW_MIN}m"
}

check_falco() {
  should_run falco || return 0
  section "Falco (last 1h)"
  local logs="${DATA[ctl:falco_logs]}"
  if [ -z "$logs" ]; then record INFO "falco" "no falco pods found / no logs - skipping"; return; fi
  local hits; hits=$(grep -icE 'critical|emergency' <<<"$logs" || true)
  if [ "${hits:-0}" -gt 0 ]; then
    record FAIL "falco" "$hits critical/emergency alert line(s) in the last hour"
  else
    record PASS "falco" "no critical/emergency alerts in the last hour"
  fi
}

check_node_status
check_api_health
check_node_resources
check_node_os_metrics
check_pods
check_storage
check_argocd
check_controllers
check_certs
check_events
check_falco

printf '\n%b== Summary ==%b\n' "$C_BLU" "$C_RST"
printf '  %bPASS%b %-4s %bWARN%b %-4s %bFAIL%b %-4s %bINFO%b %-4s   (%ss)\n' \
  "$C_GRN" "$C_RST" "$PASS_N" "$C_YEL" "$C_RST" "$WARN_N" "$C_RED" "$C_RST" "$FAIL_N" "$C_DIM" "$C_RST" "$INFO_N" "$SECONDS"

if [ "${#ISSUES[@]}" -gt 0 ]; then
  printf '\nIssues:\n'
  for i in "${ISSUES[@]}"; do printf '  - %s\n' "$i"; done
fi

if [ "$FAIL_N" -gt 0 ]; then
  printf '\n%bOverall: FAIL%b\n' "$C_RED" "$C_RST"
  exit 2
elif [ "$WARN_N" -gt 0 ]; then
  printf '\n%bOverall: WARN%b\n' "$C_YEL" "$C_RST"
  exit 1
else
  printf '\n%bOverall: PASS%b\n' "$C_GRN" "$C_RST"
  exit 0
fi
