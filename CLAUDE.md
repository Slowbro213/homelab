# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A GitOps repository for a 2-node k3s ("gentoo") homelab cluster, reconciled entirely by
Argo CD. There is no build, lint, or test tooling — the only "correctness check" is whether a
YAML manifest is valid and whether Argo CD can render/sync it. There is no application source
code here; app source lives in separate Gitea repos (e.g. `git.thanaspapa.com/thanas-papa/*`)
and this repo only holds their Kubernetes deployment manifests and the Argo CD `Application`
that points at them.

## Repository layout

- `clusters/gentoo/root-app.yaml` — the single Argo CD "app of apps" root `Application`. It
  points at `clusters/gentoo/apps` with `directory.recurse: true`, so **every** `Application`
  and `AppProject` manifest anywhere under that directory is auto-discovered and synced —
  there is no separate registration step.
- `clusters/gentoo/apps/projects.yaml` — defines the Argo CD `AppProject`s (`gentoo-root`,
  `infra`, `apps`, `frontends`, `security`) that every `Application` below must reference via
  `spec.project`. Each project whitelists which Helm repos (`sourceRepos`), namespaces
  (`destinations`), and resource kinds it may create. When adding a new source repo or a new
  destination namespace, update the relevant `AppProject` here first or the sync will be
  rejected.
- `clusters/gentoo/apps/infra/*.yaml` — one `Application` manifest per infra component
  (cert-manager, gitea, postgres, minio, vault, tailscale-operator, kyverno, falco, ...).
  These typically pull a Helm chart directly from its upstream repo and set `spec.project: infra`.
- `clusters/gentoo/apps/tailscale/*.yaml`, `clusters/gentoo/apps/secrets/*.yaml`,
  `clusters/gentoo/apps/security-baseline.yaml`, `clusters/gentoo/apps/programmingclub.yaml`,
  `clusters/gentoo/apps/cntdwn.yaml`, `clusters/gentoo/apps/whoami.yaml` — one `Application`
  per remaining workload/concern.
- `apps/<name>/` — the actual Kubernetes manifests / Helm values referenced by the
  `Application` manifests above (via `path:` for plain manifests, or `valueFiles` /
  `valuesObject` for Helm charts). A `kustomization.yaml` in these directories is what Argo CD
  actually applies when the source is manifests-only (not every `apps/<x>` dir has one — e.g.
  `apps/minio` and `apps/redis/manifests` are consumed directly, without kustomize).

## The Argo CD `Application` pattern used throughout

Two shapes recur constantly — recognize them before editing an `Application`:

1. **Helm chart + values-from-this-repo, single source list `sources:`** (see
   `clusters/gentoo/apps/infra/minio.yaml`, `infra/gitea.yaml`): the chart comes from an
   upstream Helm repo, and its values come either inline (`helm.valuesObject`) or from
   `valueFiles: [$values/apps/<name>/...]` referencing a second source in the same `sources:`
   list with `ref: values` pointing back at this repo.
2. **Plain manifests via `source.path`** (see `whoami.yaml`, `programmingclub.yaml`,
   `cntdwn.yaml`): `repoURL` + `path` pointing at a kustomize directory, either in this repo
   (`apps/<name>`) or in the app's own repo (`deploy/k8s`).

All `Application`s use `syncPolicy.automated: { enabled: true, prune: true, selfHeal: true }` —
Argo CD applies changes automatically on every push to `main`. There is no manual "deploy"
step; committing and pushing to `main` **is** the deploy. Treat every commit to this repo as
something that will be applied to the live cluster automatically.

`argocd.argoproj.io/sync-wave` annotations control ordering between `Application`s (e.g. the
CNPG operator has `sync-wave: "-5"` so it installs before anything that needs a `Cluster` CRD).
Preserve/set these deliberately when introducing ordering dependencies.

## Security & policy layer (`apps/security-baseline`)

- `namespaces.yaml` defines every namespace with Pod Security Standard labels
  (`pod-security.kubernetes.io/enforce: restricted` almost everywhere) and an opt-in
  `trust.gentoo.lan/internal-ca: "true"` label for namespaces that need the internal CA bundle
  injected (see `apps/cert-manager/internal-ca-bundle.yaml`, which uses trust-manager). New
  namespaces should get security-baseline labels, not be created ad hoc inside an app's own
  manifests.
- `kyverno-policies.yaml` holds cluster-wide `ClusterPolicy` admission rules (e.g. images may
  not use the `:latest` tag; `LoadBalancer` Services are denied unless labeled
  `homelab.slowking.dev/allow-public-load-balancer=true` or using the Tailscale
  `loadBalancerClass`). New workloads must satisfy these or add an explicit exception.
- `network-policies/<namespace>.yaml` — every namespace gets an explicit default-deny
  (`podSelector: {}`, both `Ingress`/`Egress`) plus narrow allow rules (DNS egress, specific
  ingress controllers, cross-namespace app traffic). When adding a new workload or a new
  cross-service dependency, add/extend the matching `network-policies/<namespace>.yaml` and
  wire it into `security-baseline/kustomization.yaml` — nothing gets network access by default.

## Secrets (Vault, never plaintext)

Real secret material is never committed. Secrets are pulled from Vault into the cluster via the
Vault Secrets Operator CRDs (`VaultConnection`, `VaultAuth`, `VaultStaticSecret`), see
`apps/secrets/vault-sync/` and per-app examples like
`apps/cert-manager/cloudflare-token-vaultstaticsecret.example.yaml`. Files suffixed
`.example.yaml` are templates showing the expected shape — copy and fill in the real
`path`/`mount`, then let the operator sync the K8s `Secret` into `spec.destination.name`, don't
hand-write Secret manifests with real values in this repo.

## TLS / internal CA

`apps/cert-manager/internal-issuers.yaml` sets up a self-signed root
(`gentoo-selfsigned` → `gentoo-internal-ca` cert → `gentoo-internal-ca` ClusterIssuer) used for
internal service-to-service TLS (e.g. Postgres `serverTLSSecret`, gitea's DB connection
`SSL_MODE: verify-full`). Public-facing TLS instead uses the Cloudflare DNS-01 ACME issuers in
`apps/cert-manager/cloudflare-dns01-issuers.example.yaml`. Namespaces that need to trust the
internal CA get it injected via trust-manager, gated by the
`trust.gentoo.lan/internal-ca: "true"` namespace label.

## Networking / exposure

- Internal-only admin UIs are exposed via Tailscale Ingress under `apps/tailscale/<app>/`
  (one `kustomization.yaml` + `ingress.yaml` per app, each with its own
  `clusters/gentoo/apps/tailscale/<app>.yaml` Application).
- Public-facing services go through Cloudflare Tunnel (`apps/cloudflared/`).
- Kyverno denies plain `LoadBalancer` Services outside of Tailscale's `loadBalancerClass`
  (see security-baseline above) — don't add a bare `type: LoadBalancer` Service expecting it
  to sync.

## CI/CD for application repos

This repo has no CI workflows of its own. Application source repos (frontends, tools) run their
own Gitea Actions builds using the self-hosted `gitea-runner` deployed from
`apps/gitea-runners/` (buildah-based image builds — runner label `gitea-buildah`, see
`apps/gitea-runners/runner-image/README.md` for how the tools image is built — pushed to the
internal Zot registry at `registry.gentoo.lan`), then Argo CD Image Updater (`argocd-image-updater` in
`clusters/gentoo/apps/infra/`) bumps the running digest and writes back to the app's own repo —
see the `argocd-image-updater.argoproj.io/*` annotations on `clusters/gentoo/apps/cntdwn.yaml`
for the pattern. There used to be a `templates/frontend-app/` scaffold for bootstrapping new
frontend repos with this pattern; it was removed (commit `be03df8`) — if asked to add a new
frontend app, look at `cntdwn.yaml` and `programmingclub.yaml` as the closest live references
instead.

## The live cluster ("gentoo")

Two nodes, both running **NixOS 25.11** (systemd), k3s `v1.34.5+k3s1`. Reach them directly by
SSH as `slowking` with key `-i ~/.ssh/id_ed25519` (no jump host, no login password). The old
`cachyos-x8664` / bare `tux` / `cachyos` SSH aliases are **defunct — use the IPs**:

- **`ssh slowking@192.168.1.31`** — control-plane node, hostname `cachyos` (8 cores / 13Gi RAM,
  WiFi-only laptop). `k3s.service` via `systemctl`. `kubectl`/`helm`/`kustomize` all work here
  out of the box as `slowking` with **no sudo** — `/etc/rancher/k3s/k3s.yaml` is world-readable
  and picked up automatically (no `KUBECONFIG` needed). **Do all cluster-wide `kubectl` work
  from this node.** It's also on the tailnet alongside every Tailscale-Ingress app (argocd,
  gitea, grafana, vault, minio, longhorn, authentik, alertmanager).
- **`ssh slowking@192.168.1.25`** — sole worker/agent node, hostname `tux` but its **k3s
  node-name is `registry.gentoo.lan`** (matches the cluster name; also where the internal Zot
  registry ingress resolves — `registry.gentoo.lan` → 192.168.1.25). CPU-limited i5-6200U box.
  Agent `k3s.service` via `systemctl`. `kubectl` is **not usable** here (no readable kubeconfig)
  — inspect only node-local state (Longhorn replicas, containerd, host processes). The
  `gitea-runner` is nodeSelector-pinned here (needs its Localhost seccomp profile).
- **`sudo` needs a password for `slowking`** on both nodes — don't run sudo over non-interactive
  SSH; it hangs. Everything for cluster inspection works unprivileged. (The separate `deploy`
  user has NOPASSWD sudo, used only for node rebuilds — see the nixos flake below.)
- Both nodes run **Longhorn** with local storage under `/var/lib/longhorn` (`replicas/`,
  `engine-binaries/`, `longhorn-disk.cfg`) — where PVC replica data actually lives on disk.
- Don't assume server/agent k3s versions are pinned identical; check `kubectl get nodes -o wide`.

### The nixos/ flake (node OS — deployed manually, NOT by Argo CD)

`nixos/` (repo root) is a NixOS flake defining **both nodes' OS** — the one part of this repo
**outside Argo CD's watched path**, so committing/pushing `nixos/` deploys **nothing**. The
"commit to main = deploy" rule does NOT apply here. Nodes are updated only by a deliberate
manual rebuild from a machine holding the sops age key (`~/.config/sops/age/keys.txt`):

```
cd nixos
NIX_SSHOPTS="-i ~/.ssh/gentoo_deploy_ed25519 -o StrictHostKeyChecking=no" \
  nixos-rebuild switch --flake .#cachyos --target-host deploy@192.168.1.31 --use-remote-sudo
# ...and .#tux --target-host deploy@192.168.1.25 for the worker
```

- The `deploy` user has **NOPASSWD sudo**, so `--use-remote-sudo` runs non-interactively. Build
  first with `nix build .#nixosConfigurations.<host>.config.system.build.toplevel --no-link` to
  catch eval/build errors before deploying.
- Layout: `modules/*` shared, `hosts/<host>/*` per-node hardware/role, `mkNode` in `flake.nix`.
- **Node secrets use sops-nix** (age), NOT Vault — `secrets/cluster.yaml` (+ per-host files),
  recipients in `.sops.yaml` (`ws`/`cachyos`/`tux`). The runtime decrypt key IS each machine's
  SSH host key at `/etc/ssh/ssh_host_ed25519_key` — **never manage that path via sops** (circular
  dep → nothing decrypts). Add a secret with
  `sops set secrets/cluster.yaml '["k"]["v"]' '"…"'`; inject it into a rendered config file via
  `sops.templates.<name>` (never plaintext in git or the Nix store).
- Node-local quirks the flake pins (don't rediscover): `networking.enableIPv6=false` (WiFi has
  no IPv6 → image pulls resolve AAAA and fail); `--node-label node.longhorn.io/create-default-disk=true`
  on both nodes (else Longhorn has 0 capacity, no PVC schedules); `iscsiadm` symlinked into host
  PATH for Longhorn nsenter; tux `logind.lidSwitch="ignore"`. Postgres is pinned to a PG16 image
  (`apps/postgres/cluster.yaml`) to match restored data.

### Internal registry auth (registry.gentoo.lan / Zot)

App images are pulled from the in-cluster **Zot** registry at `registry.gentoo.lan` (mirror
configured in each node's `/etc/rancher/k3s/registries.yaml`). **Zot requires auth for reads**
(its `accessControl` has no anonymous policy), so `registries.yaml` MUST carry the
`registry-admin` credential or every pull 401s → cluster-wide `ImagePullBackOff`. That file is
rendered from `sops.templates."registries.yaml"` in `nixos/modules/k3s-common.nix` (secret
`registry/password`, = the `zot-auth` Secret's `registry-admin` password). **k3s reads
registries.yaml only at startup** — after changing it, k3s/k3s-agent must restart (a
`nixos-rebuild switch` does this automatically when the unit closure changes). Zot's storage
backend is the in-cluster MinIO (bucket `zot`).

### Working on the live cluster: keep it lightweight

Cluster inspection is almost always a handful of read-only `kubectl`/SSH commands (`get`,
`describe`, `logs`, `top`) — run these directly with the Bash/SSH tools yourself rather than
spawning a subagent for them. Spawning an agent costs a fresh context (re-establishing what
the cluster is, re-reading this file) before it even runs the one command you wanted, which is
more tokens than just running it. Reserve subagents for cluster work where the *output* itself
would flood the main conversation — e.g. paging through many pods' logs, or a broad
multi-resource audit across namespaces — and even then keep the delegated task narrow (one
specific question, a capped set of commands) so the agent comes back with a short answer
instead of a wall of raw output.

## Git commit conventions

- Do not add a `Co-Authored-By` trailer (or any other co-sign/attribution line) to commit
  messages in this repo.

## Making changes safely

- Validate YAML syntax before committing (`python3 -c "import yaml,sys; yaml.safe_load_all(open(sys.argv[1]))" <file>` works since no `kubectl`/`kustomize`/`helm` binaries are installed in this environment).
- New `Application`s must reference an existing `AppProject` in `projects.yaml`, and that
  project's `sourceRepos`/`destinations`/`*ResourceWhitelist` must already permit what the
  new `Application` needs, or the sync will fail/be blocked.
- New workloads need: a namespace entry in `security-baseline/namespaces.yaml`, a
  default-deny + allow `NetworkPolicy` set in `security-baseline/network-policies/`, and to
  not violate the Kyverno policies in `security-baseline/kyverno-policies.yaml`.
- Container resource requests should be small and explicit (~10-100m CPU, ~16-256Mi memory
  request) with a memory-only limit — no CPU limit — matching the pattern in `whoami`,
  `cloudflared`, and gitea's read-only proxy. New small-app namespaces (frontend apps living
  in their own repos, created via `CreateNamespace=true`) should also get a backstop
  `LimitRange` in `apps/security-baseline/resource-limits/<namespace>.yaml`, wired into
  `security-baseline/kustomization.yaml`, since this repo doesn't control what those app
  repos' manifests request.
- Since `selfHeal: true` is on everywhere, don't rely on manually patching live cluster state —
  any drift from what's in git gets reverted automatically. Encode the desired state in the
  manifest itself (comments in `apps/postgres/cluster.yaml` and
  `apps/gitea-runners/runner.yaml` call out specific fields that had to be pinned explicitly to
  stop Argo CD from fighting an operator's defaults).
