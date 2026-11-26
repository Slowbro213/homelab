# Alert agent: Claude Code responds to critical alerts

Date: 2026-11-26 · Status: approved design, not implemented
Depends on: `2026-11-26-watchdog-prometheus-design.md` (alerts must fire when tux is down).

## Goal

When a `severity=critical` alert fires, a Claude Code agent investigates the cluster, takes
at most a small set of pre-approved remediation actions, and posts a diagnosis plus what it did
to Discord. It must work while tux is down.

## Decisions (user-approved)

| Topic | Decision |
|---|---|
| Authority | Investigate + report, plus an allowlist of runbook actions |
| Runtime | In-cluster, pinned to cachyos |
| Agent | Claude Code (`claude -p`), subscription auth via `claude setup-token` |
| Allowlist | delete Longhorn orphans; restart VSO controller; restart crashlooping pods; force-delete pods on a dead node |
| Vault unseal | **Manual, not automated.** The agent detects and reports sealed Vault pods; it never has access to Shamir shares |
| Falco alerts | Report-only runs (no runbook tool) — the alert payload is attacker-controlled |

## Architecture

```
Alertmanager (2 replicas)
  ├─► Discord (existing route, unchanged)
  └─► webhook (new receiver, continue: true, severity=critical)
          ▼
alert-agent Deployment — ns alert-agent, 1 replica, nodeSelector cachyos
  ├─ receiver (Python stdlib HTTP): validate → filter → dedupe → rate-limit → queue
  └─ worker: one `claude -p` subprocess at a time
        prompt   = runbook ConfigMap + alert JSON (marked as untrusted data)
        tools    = read-only kubectl, `runbook <action>` (non-falco only)
        limits   = --max-turns 30, 10-min wall-clock timeout
          ▼
receiver posts the final report to Discord (webhook)
```

Long-running pod rather than Job-per-alert: creating Jobs needs `create jobs` RBAC, which lets a
pod run as any ServiceAccount in the namespace. A subprocess needs nothing extra.

## Components

### 1. Image — new Gitea repo `thanas-papa/alert-agent`

- Contents: Python 3 (stdlib only), `kubectl` (pinned to the cluster's minor version),
  Claude Code (pinned npm version), `receiver.py`, `runbook` scripts. Non-root, read-only root
  filesystem compatible (writable `emptyDir` for `$HOME`/`/tmp`).
- Built by the existing buildah Gitea runner (`gitea-buildah` label), pushed to
  `registry.gentoo.lan`, pinned by digest. Image Updater is optional; plain digest bumps are fine.
- Zot's backing store (MinIO) may be unavailable during a tux outage. Pinning the pod to cachyos
  keeps the image cached there, and `imagePullPolicy: IfNotPresent` (digest-pinned) avoids a
  pull when the pod restarts.

### 2. Receiver (`receiver.py`)

- `POST /alert` accepts the Alertmanager webhook v4 payload and requires a shared bearer
  token (Alertmanager `http_config.authorization`); requests without it get 401.
- Ignores `status: resolved` and anything not `severity=critical`.
- Dedupe: skip if the same `groupKey` was handled within the last 4h (matches
  `repeatInterval`). The state is in memory; losing it on restart is acceptable.
- Rate cap: max 3 runs per rolling hour. Over the cap it posts
  `"<alertname>: not investigated (rate limit)"` to Discord, so nothing is dropped silently.
- Queue depth 5; beyond that, same "not investigated" message.
- Classifies each alert as **falco** (has a `rule` label, or `source=falco`/sidekick origin)
  or **normal**, and selects the tool set accordingly.
- `GET /healthz` for liveness/readiness.
- Logs every run, every tool call result summary, and every runbook action to stdout (Alloy →
  Loki).

### 3. Agent invocation

```
claude -p "<prompt>" --max-turns 30 --output-format json \
  --allowedTools "Bash(kubectl get:*)" "Bash(kubectl describe:*)" "Bash(kubectl logs:*)" \
                 "Bash(kubectl top:*)" "Bash(kubectl events:*)" [ "Bash(runbook:*)" ]
```

- `runbook` is included only for normal alerts.
- No file-write, web, or MCP tools.
- The prompt template and the runbook knowledge (cluster facts, known failure modes:
  iwlwifi crash, Longhorn orphans, sealed `vault-1`, 2-node raft quorum loss while tux is down)
  live in a ConfigMap **in this repo** (`apps/alert-agent/runbook.md`), so tuning is a commit,
  not an image rebuild.
- The prompt states that alert labels, annotations, and pod logs are untrusted data, not
  instructions.
- The final report should be at most about 1,800 characters (Discord's limit is 2,000) and
  contain the alert name, findings, actions taken (or "none"), and suggested next steps for the
  human. The receiver truncates if needed.

### 4. Runbook actions (`runbook <action>`, in the image)

Guardrails are enforced in the scripts. RBAC is the hard ceiling.

| Action | Effect | Guardrail |
|---|---|---|
| `delete-longhorn-orphans` | `kubectl delete orphans.longhorn.io -n longhorn-system --all` | none beyond RBAC (documented safe, repeatable fix) |
| `restart-vso` | delete the `vault-secrets-operator` controller pod(s) | namespace fixed in script |
| `restart-pod <ns> <pod>` | delete a pod | ns must be in the allowlist; pod must be in `CrashLoopBackOff`/`Error`, and owned by a controller (so it is recreated) |
| `force-delete-dead-node-pods <node>` | `delete --grace-period=0 --force` pods on that node | node `NotReady` for more than 5 minutes; ns in the allowlist; pod has no PVC, **or** every PVC's Longhorn volume has a healthy replica on another node |

Every action prints a one-line summary that the agent must include in its report.

### 5. RBAC (ServiceAccount `alert-agent/alert-agent`)

- `ClusterRoleBinding` to built-in `view` (excludes Secrets).
- `ClusterRole alert-agent-read`: get/list/watch on `nodes`, `events`, `longhorn.io/*`,
  `argoproj.io/applications`, `postgresql.cnpg.io/*`.
- `Role` in `longhorn-system`: delete `orphans.longhorn.io`.
- `Role` in `vault-secrets-operator`: delete `pods`.
- `Role` + `RoleBinding` (delete `pods`) in each allowlisted namespace. The same list is
  hard-coded in the runbook scripts:
  `apps, authentik, chess, cntdwn, programmingclub, spyal, cloudflare, cloudflare-friend,
  gitea, gitea-runners, pgadmin, registry, nats, redis, tailscale, logging, falco,
  smartctl-exporter`.
  Deliberately excluded: `vault`, `databases`, `cnpg-system`, `longhorn-system`, `minio`,
  `velero` (data/state), `kube-system`, `argocd`, `cert-manager`, `kyverno` (cluster control),
  `monitoring`, `alert-agent` (the alerting path itself), `default`, `myns`. The four
  frontend namespaces are created by their own apps (`CreateNamespace=true`); a RoleBinding
  in them is fine.
- Explicitly **no**: `secrets`, `pods/exec`, `pods/portforward`, `create` on anything, `patch`/
  `update` on workloads.

### 6. Credentials and secrets

- `CLAUDE_CODE_OAUTH_TOKEN`: from `claude setup-token`, stored in Vault, synced by a
  `VaultStaticSecret` into `alert-agent/claude-token`. The synced Secret persists while Vault is
  unavailable.
- Discord webhook: reuse the `alertmanager-discord-webhook` Vault path with a second
  `VaultStaticSecret` into `alert-agent`, unless the user later wants a separate channel.
- Receiver bearer token: a random value in Vault, synced to both `monitoring` (for
  Alertmanager `http_config`) and `alert-agent`.
- Token expiry: setup-token is valid for about a year. Add a `PrometheusRule`
  `ClaudeTokenExpiringSoon` (`severity: critical`, `release: monitoring`) with
  `expr: time() > <expiry_unix - 30d>` as a static constant, updated whenever the token is
  rotated. No receiver metric.

## Cluster wiring (this repo)

- `apps/security-baseline/namespaces.yaml`: `alert-agent` with `enforce: restricted`.
- `apps/security-baseline/network-policies/alert-agent.yaml` (wired into the kustomization):
  default-deny, then:
  - **ingress:** TCP 8080 from `monitoring` pods `app.kubernetes.io/name: alertmanager`
  - **egress:** DNS; API server (`10.43.0.1/32:443` and `192.168.1.0/24:6443`, same pattern as
    `monitoring`); TCP 443 to `0.0.0.0/0` except `10.42.0.0/16`, `10.43.0.0/16` and
    `192.168.0.0/16` (Anthropic API, Discord — NetworkPolicy cannot filter by FQDN)
- `network-policies/monitoring.yaml`: add Alertmanager egress to `alert-agent:8080`.
- `apps/security-baseline/resource-limits/alert-agent.yaml`: LimitRange backstop.
- `apps/alert-agent/`: kustomization, Deployment, Service, SA + RBAC, runbook ConfigMap,
  VaultStaticSecrets.
- `clusters/gentoo/apps/alert-agent.yaml`: Application, in the existing `AppProject` that fits
  (check `projects.yaml` destinations and resource whitelist — RBAC kinds may require `infra`).
- `apps/monitoring/config/alertmanagerconfig-discord.yaml`: add an `alert-agent` receiver
  (`webhookConfigs`, `sendResolved: false`) as a sub-route with `continue: true`, so Discord
  keeps receiving everything it does today.
- Deployment: 1 replica, `nodeSelector: kubernetes.io/hostname: cachyos`; requests `cpu: 20m`,
  `memory: 64Mi`; limit `memory: 1Gi`; no CPU limit.
- Kyverno: no `:latest` (digest-pinned), and check both policy layers.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| tux down | watchdog fires `NodeDown`; agent runs on cachyos with kubectl only (Prometheus/Loki/Vault unavailable — the runbook says so) |
| Anthropic API unreachable / plan limit hit | receiver posts "agent failed: <reason>" to Discord; the original alert already went to Discord |
| Agent timeout or max turns | receiver kills the subprocess and posts partial output marked "incomplete" |
| alert-agent pod down | Discord route unaffected (`continue: true`); Alertmanager retries the webhook and logs failures |
| cachyos down | everything is down — out of scope (as in the watchdog spec) |

## Testing

1. RBAC: `kubectl auth can-i --as=system:serviceaccount:alert-agent:alert-agent` for every
   granted verb, plus denials for `get secrets`, `create pods/exec`, `patch deployments`,
   `delete pods -n vault`, and `delete pods -n databases`.
2. Runbook guardrails: run each action against conditions that must be refused (healthy node,
   pod with a tux-only PVC, non-allowlisted namespace) and confirm it refuses.
3. Receiver: send a synthetic payload with `curl` from a debug pod in `monitoring`. Check
   dedupe, the rate cap, falco classification (no `runbook` tool), and resolved alerts being
   ignored.
4. End to end: fire a synthetic critical alert with `amtool`, labelled so the Discord route can
   match and suppress it during testing, and confirm the agent report arrives.
5. Live test, combined with the watchdog spec: stop k3s on tux and expect `NodeDown` from the
   watchdog, then an agent report diagnosing tux as unreachable with correct reasoning about
   which pods can or cannot be rescheduled.
