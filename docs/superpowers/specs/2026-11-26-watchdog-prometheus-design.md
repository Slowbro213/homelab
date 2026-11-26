# Watchdog Prometheus: alerting that survives tux going down

Date: 2026-11-26 · Status: approved design, not implemented

## Problem

Alertmanager already runs 2 replicas with hard anti-affinity, but Prometheus — the thing that
evaluates rules — is a single replica whose only Longhorn replica lives on tux
(`registry.gentoo.lan`). Verified live 2026-11-26: `prometheus-...-0` and `loki-0` both run on
tux with their volume replicas on tux. When tux dies, Prometheus dies with it and `NodeDown`
can never fire for the node that is down. Observed in the 2026-09-03 power-off test.

## Goal and scope

- **In scope:** `NodeDown` for tux fires to Discord while tux is down.
- **Out of scope (user decision):** cachyos down, whole-cluster or internet loss (no external
  dead-man's switch), Loki-ruler alerts during a tux outage, any rule other than `NodeDown`,
  Prometheus HA proper.
- **Constraint:** the lightest option possible (cachyos is at ~64% memory).

## Design

A second, minimal `Prometheus` CR managed by the existing prometheus-operator, living in
`apps/monitoring/config/` (synced by the existing `monitoring-config` Application — no new
Application, no new chart).

| Field | Value |
|---|---|
| Name | `watchdog` (namespace `monitoring`) |
| Replicas | 1 |
| Placement | required pod anti-affinity against `prometheus=monitoring-kube-prometheus-prometheus` on `kubernetes.io/hostname` — always on the node the main Prometheus is *not* on |
| Scrape targets | `serviceMonitorSelector` matching only the node-exporter ServiceMonitor (`app.kubernetes.io/name: prometheus-node-exporter`); empty pod/probe monitor selectors; `serviceMonitorNamespaceSelector` limited to `monitoring` |
| Rules | `ruleSelector` matching `prometheus-watchdog: "true"` only |
| Storage | none (`emptyDir`, operator default); `retention: 2h` |
| Resources | requests `cpu: 10m`, `memory: 32Mi`; limit `memory: 128Mi`; no CPU limit |
| Alerting | the existing Alertmanager service `monitoring-kube-prometheus-alertmanager:9093` |
| ServiceAccount | reuse the main Prometheus's SA (`monitoring-kube-prometheus-prometheus`), which already has discovery RBAC |

### Rule

Move `NodeDown` out of `prometheus-rule-node-health.yaml` into its own
`PrometheusRule` `node-down`, labelled with **both** `release: monitoring` (main Prometheus's
`ruleSelector`) and `prometheus-watchdog: "true"`. Both Prometheuses load the same object — one
source of truth, no duplicated expression. Expression, `for: 2m`, labels and annotations are
unchanged.

### Alert flow

watchdog Prometheus → Alertmanager replica on cachyos → existing `severity=critical` Discord
route. No Alertmanager config change.

### Duplicates

Watchdog and main both fire only when node-exporter is down on a node that is otherwise up
(both Prometheuses alive). Their `prometheus` external label differs, so Alertmanager won't
dedupe them — two Discord messages. Accepted; no relabeling.

## Policy checks

- **NetworkPolicy:** operator-created pods carry `app.kubernetes.io/name: prometheus`, so the
  existing `monitoring` rules (egress to `192.168.1.0/24:9100`, API server, Alertmanager 9093;
  `allow-alertmanager-ingress-from-prometheus`) should already cover it. Verify, don't assume.
- **Kyverno:** check both policy layers (`apps/security-baseline/kyverno-policies.yaml` and the
  Kyverno chart's pod-security pack). Operator-generated pods include the config-reloader
  sidecar; confirm it passes the same way the main Prometheus pod does.

## Testing

1. `kubectl apply --dry-run=server` of the new manifests on 192.168.1.31.
2. After sync: the watchdog pod is Running on cachyos; the `up{job="node-exporter"}` query in
   its UI (port-forward) returns both nodes; its rule list shows only `NodeDown`.
3. Measure actual memory with `kubectl top pod` and adjust the limit if needed.
4. Live test (shared with the alert-agent spec): cleanly stop k3s on tux and expect
   `NodeDown` in Discord within about 3 minutes, then a resolved message after tux returns.

## Amendment (2026-11-26, after the live test): Alertmanager storage → emptyDir

The live power-off test delivered FIRING (tux off 19:05:02, firing 19:07:53, Discord ~19:08)
but **no RESOLVED**. Both Alertmanager replicas' single-replica Longhorn volumes lived on tux.
When tux returned, Longhorn salvaged the volumes and requested a remount, which recreated the
cachyos Alertmanager pod mid-alert; its notification log was gone, so the resolved notification
had nothing to resolve and was never sent. Had that pod restarted *during* the outage, it could
not have mounted its volume and FIRING would have been lost too.

Fix: drop `alertmanagerSpec.storage` in `clusters/gentoo/apps/infra/monitoring.yaml`, so the
operator uses `emptyDir`. Alertmanager's on-disk state is only the notification log and
silences, and the two replicas gossip both; a restarted replica pulls them back from its peer
on join. Silences are lost only if both replicas restart at once (accepted). The two old PVCs
(reclaim `Retain`) are deleted after the rollout. No silences existed at the time of the change.

Retest: repeat the power-off and expect both FIRING and RESOLVED in Discord.
