# Kube-apiserver audit logging + alerting, and flannel encryption

Status: approved, not yet implemented.

## Context

Two independent NixOS-side infra changes were attempted in an earlier session while the
nodes weren't reachable, and never actually landed (nothing in git history or the working
tree matches them). This spec redefines both from scratch, now that the nodes are reachable
again. They're unrelated subsystems (observability vs. networking) but small enough to design
together.

1. View kube-apiserver audit logs in Grafana via the existing Loki/Alloy stack, and get
   Discord alerts on certain audit events.
2. Encrypt inter-node pod traffic, currently plaintext under flannel's `host-gw` backend.

## Section 1 — Audit logging (kube-apiserver → file → Loki)

- `nixos/modules/k3s-server.nix` (only the control-plane node runs the apiserver) gets new
  `kube-apiserver-arg` flags:
  - `audit-log-path=/var/log/kubernetes/audit/audit.log`
  - `audit-policy-file=/etc/rancher/k3s/audit-policy.yaml`
  - `audit-log-maxage=7`
  - `audit-log-maxbackup=5`
  - `audit-log-maxsize=100`
- New static asset `nixos/assets/audit-policy.yaml`, wired in via
  `environment.etc."rancher/k3s/audit-policy.yaml".source = ../assets/audit-policy.yaml;` —
  same pattern this repo already uses for `nixos/assets/gentoo-internal-ca.crt` in
  `k3s-common.nix`. Policy: `Metadata` level for every rule (who/verb/resource/when, no
  request/response bodies) — chosen to keep volume low relative to Loki's 168h retention and
  10Gi PVC, and because secret values in the audit log would make the audit log itself
  sensitive.
- `systemd.tmpfiles.rules` on the control-plane node ensures `/var/log/kubernetes/audit`
  exists with sane permissions before k3s starts (kube-apiserver creates the log file itself
  but not necessarily the parent directory).
- `clusters/gentoo/apps/infra/logging/alloy-logs.yaml` (the Alloy DaemonSet, `alloy` Helm
  chart) gets:
  - An extra hostPath volume + volumeMount for `/var/log/kubernetes/audit` (read-only).
  - A new `loki.source.file` component (with `local.file_match` discovery over that path)
    forwarding to the existing `loki.write "default"` receiver, labeled `job="kube-audit"`.
  - Only the Alloy pod scheduled on `cachyos` will actually find files under that path — on
    the worker the mount/discovery is a harmless no-op (0 targets found).

## Section 2 — Loki-based alerting on the audit log

- Enable Loki's ruler in `clusters/gentoo/apps/infra/logging/loki.yaml`
  (`deploymentMode: SingleBinary`, so ruler runs in the same `singleBinary` process):
  - `loki.ruler.alertmanager_url: http://monitoring-kube-prometheus-alertmanager.monitoring.svc.cluster.local:9093`
    — the same Alertmanager instance Falco and Prometheus rules already use.
  - Rule storage: `local` type, rules supplied via a ConfigMap of static LogQL alert rules
    committed in git (no need for the dynamic ruler HTTP API for two fixed rules).
- Two alert rules, both labeled `severity: critical` so they automatically match the existing
  `route.matchers` in `apps/monitoring/config/alertmanagerconfig-discord.yaml` and land in
  Discord — **no changes needed to that file**:
  1. **Failed/forbidden request spike**: `count_over_time` over a 5m window of audit lines
     where `responseStatus.code` is `401` or `403`, alerting above a threshold (e.g. >20 in
     5m). Catches brute-forcing or a misconfigured client hammering the API.
  2. **exec/attach/portforward**: any audit line where `objectRef.subresource` matches
     `exec|attach|portforward`. Fires on every occurrence, including the operator's own manual
     `kubectl exec` debugging (as happened repeatedly during the 2026-08-09 incident response
     that motivated this spec) — not filtered by default, since excluding the operator's own
     identity would blind the alert to exactly the scenario (an unexpected shell into a pod)
     it exists to catch. Revisit the noise/signal tradeoff after living with it.

## Section 3 — Encrypt inter-node traffic (flannel wireguard-native)

- `nixos/modules/k3s-server.nix`: change `--flannel-backend=host-gw` to
  `--flannel-backend=wireguard-native`. This is a server-only flag — agents read the backend
  from the server automatically, so `nixos/modules/k3s-agent.nix` needs no backend change.
- Add `boot.kernelModules = [ "wireguard" ]` on both nodes so the module loads explicitly
  rather than relying on implicit autoload (kernel is 6.12.93, which supports it).
- Add `networking.firewall.allowedUDPPorts = [ 51820 ];` to both `k3s-server.nix` and
  `k3s-agent.nix` — WireGuard needs this open bidirectionally between the two node IPs;
  nothing currently opens a UDP port for flannel since `host-gw` doesn't tunnel at all.
- **Rollout risk**: switching flannel backends on an already-running cluster is not a
  hot-swap — it requires restarting k3s on both nodes so they regenerate their flannel
  netconf under the new backend. Expect a brief (seconds-to-low-minutes) pod-to-pod network
  interruption while both sides restart and the WireGuard tunnel establishes. Apply this
  deliberately (not bundled with unrelated rebuilds), and confirm cross-node pod connectivity
  afterward (e.g. a pod on one node reaching a pod/service on the other) before considering it
  done.

## Out of scope

- Filtering the exec/attach/portforward alert by identity (deferred pending real-world noise).
- Any audit policy level beyond `Metadata` (e.g. capturing request/response bodies).
- IPsec as a flannel backend (considered and rejected in favor of wireguard-native).
