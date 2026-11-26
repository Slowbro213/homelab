# Watchdog Prometheus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `NodeDown` reaches Discord while tux (`registry.gentoo.lan`) is down, by adding a minimal second Prometheus that always runs on the node the main Prometheus is not on.

**Architecture:** A `Prometheus` CR named `watchdog`, managed by the existing prometheus-operator (v0.90.1) in namespace `monitoring`, synced by the existing `monitoring-config` Argo CD Application from `apps/monitoring/config/`. It scrapes only the existing node-exporter ServiceMonitor and loads only one `PrometheusRule`, `node-down`. That rule is split out of `node-health` and labelled so both the main Prometheus and the watchdog load it. Alerts go to the existing 2-replica Alertmanager → Discord route, unchanged.

**Tech Stack:** prometheus-operator CRDs (`monitoring.coreos.com/v1`), kustomize (via `kubectl kustomize`), Argo CD auto-sync, Prometheus v3.11.3.

**Spec:** `docs/superpowers/specs/2026-11-26-watchdog-prometheus-design.md`

## Global Constraints

- Pushing to `main` **is** the deploy (Argo CD automated sync, prune, selfHeal). Do not push until the task says so.
- No explanatory comments in YAML files in this repo; put reasoning in commit messages (user preference).
- No `Co-Authored-By` or other attribution trailer in commit messages (CLAUDE.md).
- Image tags must not be `:latest` (Kyverno `disallow-latest-image-tag`); pin `quay.io/prometheus/prometheus:v3.11.3` to match the main Prometheus.
- Resources: requests `cpu: 10m`, `memory: 32Mi`; limit `memory: 128Mi`; **no CPU limit**.
- Watchdog loads only `NodeDown`. No other rules, no extra scrape targets, no PVC, `retention: 2h`.
- Pod security context must match the main Prometheus: `fsGroup: 2000`, `runAsGroup: 2000`, `runAsNonRoot: true`, `runAsUser: 1000`, `seccompProfile: RuntimeDefault`.
- Workstation tooling: `kubectl kustomize` works locally, but the local kubectl context is a dead minikube. Run anything that needs the API on the control-plane node with `ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 '<cmd>'`. The node has no `python3`; parse JSON on the workstation.
- No `sudo` as `slowking` over SSH (it hangs waiting for a password).
- Scratch files go in `SCRATCH=/tmp/claude-1000/-home-slowking-Github-homelab/2def36b9-3e25-4053-9c02-2a9effb20021/scratchpad`. Set it at the start of each task, since tasks may run in separate shells. All commands run from the repo root, `/home/slowking/Github/homelab`.

## Facts verified on the live cluster (2026-11-26)

- Main Prometheus: CR `monitoring-kube-prometheus-prometheus`, pod `prometheus-monitoring-kube-prometheus-prometheus-0`, pod label `prometheus=monitoring-kube-prometheus-prometheus`, SA `monitoring-kube-prometheus-prometheus`, `ruleSelector`/`serviceMonitorSelector` both `{matchLabels: {release: monitoring}}`, currently on `registry.gentoo.lan` (tux) with its only Longhorn replica on tux.
- Alerting block on the main CR: `alertmanagers: [{apiVersion: v2, name: monitoring-kube-prometheus-alertmanager, namespace: monitoring, pathPrefix: /, port: http-web}]`.
- Node-exporter ServiceMonitor `monitoring-prometheus-node-exporter` has labels `app.kubernetes.io/name=prometheus-node-exporter`, `release=monitoring`; it yields `up{job="node-exporter", instance="192.168.1.25:9100"|"192.168.1.31:9100"}`.
- The generated scrape config drops only `Failed|Succeeded` pods, not not-ready endpoints, so a dead node's target should stay and report `up=0` instead of disappearing (re-verified in Task 4 Step 3).
- NetworkPolicies in `apps/security-baseline/network-policies/monitoring.yaml` already cover any pod labelled `app.kubernetes.io/name: prometheus` (the operator sets this on every Prometheus pod): egress to `192.168.1.0/24:9100`, the API server, Alertmanager `:9093`, plus `allow-alertmanager-ingress-from-prometheus`. No NetworkPolicy change is expected; Task 2 verifies this.

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `apps/monitoring/config/prometheus-rule-node-down.yaml` | Create | The single `NodeDown` rule, loaded by both Prometheuses |
| `apps/monitoring/config/prometheus-rule-node-health.yaml` | Modify (delete lines 12–20) | Remaining node-health rules (SMART, PSI), main Prometheus only |
| `apps/monitoring/config/prometheus-watchdog.yaml` | Create | The `watchdog` Prometheus CR |
| `apps/monitoring/config/kustomization.yaml` | Modify | Register the two new files |
| `CLAUDE.md` | Modify (Alerting section) | One paragraph documenting the watchdog |

---

### Task 1: Split `NodeDown` into its own dual-labelled PrometheusRule

**Files:**
- Create: `apps/monitoring/config/prometheus-rule-node-down.yaml`
- Modify: `apps/monitoring/config/prometheus-rule-node-health.yaml:12-20`
- Modify: `apps/monitoring/config/kustomization.yaml`

**Interfaces:**
- Produces: a `PrometheusRule` `monitoring/node-down` with labels `release: monitoring` **and** `prometheus-watchdog: "true"`, containing exactly one rule `NodeDown`. Task 2's `ruleSelector` matches `prometheus-watchdog: "true"`.

- [ ] **Step 1: Record the current rendered rule, so you can prove it is unchanged**

```bash
cd /home/slowking/Github/homelab
SCRATCH=/tmp/claude-1000/-home-slowking-Github-homelab/2def36b9-3e25-4053-9c02-2a9effb20021/scratchpad
kubectl kustomize apps/monitoring/config > "$SCRATCH/before.yaml"
grep -c "alert: NodeDown" "$SCRATCH/before.yaml"
```

Expected: `1`

- [ ] **Step 2: Create `apps/monitoring/config/prometheus-rule-node-down.yaml`**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: node-down
  namespace: monitoring
  labels:
    release: monitoring
    prometheus-watchdog: "true"
spec:
  groups:
    - name: node-down
      rules:
        - alert: NodeDown
          expr: up{job="node-exporter"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Node unreachable: {{ $labels.instance }}"
            description: "Prometheus has been unable to scrape node-exporter on {{ $labels.instance }} for at least 2m — the node is likely powered off, crashed, or network-unreachable."
```

- [ ] **Step 3: Remove `NodeDown` from `apps/monitoring/config/prometheus-rule-node-health.yaml`**

Delete exactly this block (currently lines 12–20, including the trailing blank line), and leave `- name: node-health` / `rules:` followed directly by `- alert: SmartDiskFailing`:

```yaml
        - alert: NodeDown
          expr: up{job="node-exporter"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Node unreachable: {{ $labels.instance }}"
            description: "Prometheus has been unable to scrape node-exporter on {{ $labels.instance }} for at least 2m — the node is likely powered off, crashed, or network-unreachable."

```

- [ ] **Step 4: Register the new file in `apps/monitoring/config/kustomization.yaml`**

The `resources:` list becomes:

```yaml
resources:
  - prometheus-rule-alertmanager-test.yaml
  - prometheus-rule-node-health.yaml
  - prometheus-rule-node-down.yaml
  - alertmanagerconfig-discord.yaml
  - grafana-dashboard-node-health.yaml
  - servicemonitor-smartctl-exporter.yaml
```

- [ ] **Step 5: Verify the render: still exactly one `NodeDown`, now in `node-down`, with an identical expression**

```bash
kubectl kustomize apps/monitoring/config > "$SCRATCH/after.yaml"
grep -c "alert: NodeDown" "$SCRATCH/after.yaml"
grep -B12 "alert: NodeDown" "$SCRATCH/after.yaml" | grep -E "name: node-down|prometheus-watchdog|release: monitoring"
diff <(grep -A8 "alert: NodeDown" "$SCRATCH/before.yaml") <(grep -A8 "alert: NodeDown" "$SCRATCH/after.yaml") && echo RULE_UNCHANGED
```

Expected: `1`; the lines `name: node-down`, `prometheus-watchdog: "true"`, `release: monitoring`; then `RULE_UNCHANGED`.

- [ ] **Step 6: Server-side dry-run against the live API**

```bash
kubectl kustomize apps/monitoring/config | ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl apply --dry-run=server -f -'
```

Expected: `prometheusrule.monitoring.coreos.com/node-down created (server dry run)` and `node-health configured (server dry run)`, with no errors. Other objects show `unchanged` or `configured`.

- [ ] **Step 7: Commit (do not push yet)**

```bash
git add apps/monitoring/config/prometheus-rule-node-down.yaml \
        apps/monitoring/config/prometheus-rule-node-health.yaml \
        apps/monitoring/config/kustomization.yaml
git commit -m "monitoring: split NodeDown into its own PrometheusRule

Labelled both release=monitoring (main Prometheus) and
prometheus-watchdog=true so the upcoming watchdog Prometheus can load
the same object, with no duplicated expression. Rule body unchanged."
```

---

### Task 2: Add the `watchdog` Prometheus CR

**Files:**
- Create: `apps/monitoring/config/prometheus-watchdog.yaml`
- Modify: `apps/monitoring/config/kustomization.yaml`

**Interfaces:**
- Consumes: `PrometheusRule` label `prometheus-watchdog: "true"` (Task 1); the existing ServiceMonitor label `app.kubernetes.io/name: prometheus-node-exporter`; the existing SA `monitoring-kube-prometheus-prometheus`; the main Prometheus pod label `prometheus: monitoring-kube-prometheus-prometheus`.
- Produces: pod `prometheus-watchdog-0` (operator naming: `prometheus-<name>-<ordinal>`) with labels `prometheus: watchdog` and `app.kubernetes.io/name: prometheus`, serving on port 9090. Task 3 port-forwards to it.

- [ ] **Step 1: Confirm it doesn't exist yet (the failing check)**

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 'kubectl -n monitoring get prometheus watchdog'
```

Expected: `Error from server (NotFound): prometheuses.monitoring.coreos.com "watchdog" not found`

- [ ] **Step 2: Create `apps/monitoring/config/prometheus-watchdog.yaml`**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: watchdog
  namespace: monitoring
spec:
  replicas: 1
  version: v3.11.3
  image: quay.io/prometheus/prometheus:v3.11.3
  serviceAccountName: monitoring-kube-prometheus-prometheus
  retention: 2h
  scrapeInterval: 30s
  evaluationInterval: 30s
  serviceMonitorSelector:
    matchLabels:
      app.kubernetes.io/name: prometheus-node-exporter
  serviceMonitorNamespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: monitoring
  ruleSelector:
    matchLabels:
      prometheus-watchdog: "true"
  ruleNamespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: monitoring
  alerting:
    alertmanagers:
      - apiVersion: v2
        name: monitoring-kube-prometheus-alertmanager
        namespace: monitoring
        pathPrefix: /
        port: http-web
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              prometheus: monitoring-kube-prometheus-prometheus
          topologyKey: kubernetes.io/hostname
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 128Mi
  securityContext:
    fsGroup: 2000
    runAsGroup: 2000
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
```

`podMonitorSelector`, `probeSelector` and `scrapeConfigSelector` are deliberately left unset: on a `Prometheus` CR, a nil selector selects nothing. No `storage:` block means the operator uses an `emptyDir`.

- [ ] **Step 3: Register it in `apps/monitoring/config/kustomization.yaml`**

```yaml
resources:
  - prometheus-rule-alertmanager-test.yaml
  - prometheus-rule-node-health.yaml
  - prometheus-rule-node-down.yaml
  - prometheus-watchdog.yaml
  - alertmanagerconfig-discord.yaml
  - grafana-dashboard-node-health.yaml
  - servicemonitor-smartctl-exporter.yaml
```

- [ ] **Step 4: Server-side dry-run (schema + admission, including Kyverno on the CR)**

```bash
kubectl kustomize apps/monitoring/config | ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl apply --dry-run=server -f -'
```

Expected: `prometheus.monitoring.coreos.com/watchdog created (server dry run)`, with no `unknown field` errors and no Kyverno denials.

- [ ] **Step 5: Confirm the Argo CD project allows the `Prometheus` kind for `monitoring-config`**

```bash
grep -n -A40 "name: infra" clusters/gentoo/apps/projects.yaml | grep -nE "namespaceResourceWhitelist|namespaceResourceBlacklist|monitoring.coreos.com|group: '\*'|kind: '\*'"
```

Expected: either a `group: '*'` / `kind: '*'` whitelist entry, or `monitoring.coreos.com` listed. If neither appears and a whitelist exists, add `{group: monitoring.coreos.com, kind: Prometheus}` to the `infra` project's `namespaceResourceWhitelist` as part of this task.

- [ ] **Step 6: Confirm the NetworkPolicies already cover the new pod (no edits expected)**

```bash
grep -nE "app.kubernetes.io/name: prometheus$|port: 9100|port: 9093" apps/security-baseline/network-policies/monitoring.yaml
```

Expected: `port: 9100` under the `192.168.1.0/24` egress rule (`podSelector: {}`), and `app.kubernetes.io/name: prometheus` in `allow-prometheus-to-alertmanager-egress` and `allow-alertmanager-ingress-from-prometheus`. All are label-based, so they match the watchdog pod.

- [ ] **Step 7: Commit (do not push yet)**

```bash
git add apps/monitoring/config/prometheus-watchdog.yaml apps/monitoring/config/kustomization.yaml
git commit -m "monitoring: add watchdog Prometheus that survives tux going down

The main Prometheus and its only Longhorn replica live on tux, so when
tux dies NodeDown can never fire. The watchdog is a second, minimal
Prometheus CR with required anti-affinity against the main one, so it
always runs on the other node. It scrapes only node-exporter, loads only
the node-down rule, keeps 2h in an emptyDir (no PVC that could be stuck
on a dead node), and requests 10m/32Mi with a 128Mi memory limit. It
sends to the same Alertmanager, whose replicas are already spread
across both nodes."
```

(If Step 5 required a `projects.yaml` edit, add that file to this commit.)

---

### Task 3: Deploy and verify the watchdog on the live cluster

**Files:**
- Modify: `CLAUDE.md` (Alerting section)

**Interfaces:**
- Consumes: commits from Tasks 1–2; pod `prometheus-watchdog-0`.

- [ ] **Step 1: Document the watchdog in `CLAUDE.md`**

Append this paragraph to the end of the `## Alerting` section, after the paragraph ending in `...before committing.`:

```markdown
The main Prometheus is single-replica with its only Longhorn replica on tux, so it dies with
tux. A second, minimal `Prometheus` CR, `watchdog` (`apps/monitoring/config/prometheus-watchdog.yaml`),
has required anti-affinity against the main one, so it always runs on the other node. It
scrapes only node-exporter, loads only `PrometheusRule`s labelled `prometheus-watchdog: "true"`
(today just `node-down`), and keeps 2h in an `emptyDir`. When both Prometheuses are up and a
node-exporter alone fails, `NodeDown` arrives twice in Discord (different `prometheus` external
label); that is expected. Don't add rules to the watchdog casually — its point is to stay tiny.
```

- [ ] **Step 2: Commit the doc change**

```bash
git add CLAUDE.md
git commit -m "docs: describe the watchdog Prometheus in CLAUDE.md"
```

- [ ] **Step 3: Get explicit user go-ahead, then push (this deploys)**

Ask the user before running:

```bash
git push origin main
```

- [ ] **Step 4: Wait for Argo CD to sync `monitoring-config`**

```bash
SHA=$(git rev-parse HEAD)
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 "SHA=$SHA sh -s" <<'EOF'
for i in $(seq 1 30); do
  s=$(kubectl -n argocd get application monitoring-config \
        -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.sync.revision}')
  echo "$s"
  [ "$s" = "Synced/Healthy/$SHA" ] && break
  sleep 10
done
EOF
```

Expected: ends with `Synced/Healthy/<HEAD sha>`. If it doesn't sync within 5 minutes, check `kubectl -n argocd get application monitoring-config -o jsonpath='{.status.conditions}'`.

- [ ] **Step 5: Confirm placement and resource use**

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl -n monitoring get pods -l "prometheus in (watchdog,monitoring-kube-prometheus-prometheus)" -o wide; kubectl -n monitoring top pod prometheus-watchdog-0 --containers'
```

Expected: `prometheus-watchdog-0` is `2/2 Running` on `cachyos`; the main pod is on `registry.gentoo.lan`. If the pod never appears, pod admission was probably denied (the Step 4 dry-run in Task 2 checks only the CR, not the pod). Look for the reason with `kubectl -n monitoring describe statefulset prometheus-watchdog | tail -20` and `kubectl get policyreport -n monitoring`, and check both Kyverno layers. The `prometheus` container uses well under 128Mi; record the number. If it is above ~100Mi, raise the limit to `192Mi` in `prometheus-watchdog.yaml` and commit it as a follow-up.

- [ ] **Step 6: Confirm targets, rules and Alertmanager discovery through the watchdog's API**

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl -n monitoring port-forward pod/prometheus-watchdog-0 19091:9090 >/dev/null 2>&1 & sleep 3;
   curl -s "localhost:19091/api/v1/query?query=up"; echo;
   curl -s localhost:19091/api/v1/rules; echo;
   curl -s localhost:19091/api/v1/alertmanagers; echo;
   kill %1' > "$SCRATCH/watchdog.txt"
python3 -I - "$SCRATCH/watchdog.txt" <<'EOF'
import json, sys
up, rules, ams = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("up:", sorted((r["metric"]["job"], r["metric"]["instance"], r["value"][1]) for r in up["data"]["result"]))
print("rules:", [r["name"] for g in rules["data"]["groups"] for r in g["rules"]])
print("alertmanagers:", [a["url"] for a in ams["data"]["activeAlertmanagers"]])
EOF
```

Expected:
- `up:` exactly two entries, `('node-exporter', '192.168.1.25:9100', '1')` and `('node-exporter', '192.168.1.31:9100', '1')`, and nothing else
- `rules: ['NodeDown']`
- `alertmanagers:` two URLs on port 9093 (one per Alertmanager pod)

- [ ] **Step 7: Confirm the main Prometheus still has `NodeDown` and the other node-health rules**

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl -n monitoring port-forward pod/prometheus-monitoring-kube-prometheus-prometheus-0 19090:9090 >/dev/null 2>&1 & sleep 3;
   curl -s localhost:19090/api/v1/rules; kill %1' > "$SCRATCH/main-rules.json"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sorted(r["name"] for g in d["data"]["groups"] if g["name"] in ("node-down","node-health") for r in g["rules"]))' "$SCRATCH/main-rules.json"
```

Expected: `['HighIOPressureStall', 'HighMemoryPressureStall', 'NodeDown', 'SmartDiskCriticalWarning', 'SmartDiskFailing']`, plus any other node-health rules that were already there. `NodeDown` must appear exactly once.

---

### Task 4: Live failover test (tux powered off)

This takes tux down for real. **Get explicit user go-ahead first and agree who will power tux back on** — it needs someone physically at the machine. Expect `vault-1` to come back sealed afterwards; the unseal stays manual (CLAUDE.md "Recovery notes").

**Files:** none (verification only)

- [ ] **Step 1: Baseline**

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl get nodes; kubectl -n monitoring get pods -o wide | grep -E "prometheus-|alertmanager-"'
```

Expected: both nodes `Ready`, `prometheus-watchdog-0` on `cachyos`, an Alertmanager pod on each node.

- [ ] **Step 2: Power off tux (only after user go-ahead)**

```bash
ssh -F /dev/null -i ~/.ssh/gentoo_deploy_ed25519 -o BatchMode=yes deploy@192.168.1.25 'sudo systemctl poweroff'
date -u +%H:%M:%S
```

Record the time.

- [ ] **Step 3: About 90 seconds later, confirm the watchdog sees tux as `up=0` (target kept, not dropped)**

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl -n monitoring port-forward pod/prometheus-watchdog-0 19091:9090 >/dev/null 2>&1 & sleep 3;
   curl -s "localhost:19091/api/v1/query?query=up%7Bjob%3D%22node-exporter%22%7D"; echo;
   curl -s localhost:19091/api/v1/alerts; kill %1'
```

Expected: the `192.168.1.25:9100` series is present with value `"0"`, and `NodeDown` shows as `pending` and then `firing`.

If the tux series is **absent** rather than `0`, service discovery dropped the target and `NodeDown` will never fire. Stop here and report it. The fix is a design change (for example a `ScrapeConfig` with static node targets), not an improvisation.

- [ ] **Step 4: Confirm Discord delivery**

Within about 3 minutes of the poweroff time, the user confirms a `🚨 FIRING` **NodeDown** message for `192.168.1.25:9100` in Discord. Also check Alertmanager directly:

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl -n monitoring exec alertmanager-monitoring-kube-prometheus-alertmanager-1 -c alertmanager -- amtool alert query alertname=NodeDown --alertmanager.url=http://localhost:9093'
```

Expected: one `NodeDown` alert with `instance=192.168.1.25:9100`.

- [ ] **Step 5: Power tux back on (physical), then confirm resolution**

After tux is `Ready` again:

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 'kubectl get nodes'
```

Expected: both `Ready`. Within about 5 minutes the user sees a `✅ RESOLVED` NodeDown message in Discord. A second RESOLVED may arrive from the main Prometheus once it restarts; that's fine.

- [ ] **Step 6: Post-outage checks (do not skip)**

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'for p in vault-0 vault-1; do echo -n "$p sealed="; kubectl -n vault exec $p -- env VAULT_SKIP_VERIFY=true vault status -format=json 2>/dev/null | grep -o "\"sealed\": [a-z]*"; done;
   kubectl get orphans.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l;
   kubectl -n monitoring get pods -o wide | grep -E "prometheus-"'
```

Expected / actions:
- If `vault-1` reports `"sealed": true`, tell the user. Unsealing is manual (CLAUDE.md "Recovery notes"); do not do it without them.
- Orphan count: a clean poweroff usually leaves `0`. If it's non-zero, report it; cleanup follows the documented procedure, with the user's OK.
- `prometheus-watchdog-0` is still on `cachyos`, and the main Prometheus is back `Running` on `registry.gentoo.lan`.

- [ ] **Step 7: Report the results**

Summarize for the user: the poweroff time, the time NodeDown fired in Discord, the time it resolved, the watchdog's memory use from Task 3 Step 5, and anything unexpected from Step 6.
