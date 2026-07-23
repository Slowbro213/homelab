# NixOS Migration — Status & Resume Handoff (2026-07-23)

Both `gentoo` k3s nodes were migrated from their old OSes (CachyOS / Gentoo) to **NixOS**
by backing up all persistent state to a throwaway MinIO, wiping + reinstalling via
`nixos-anywhere`, then restoring the data. **The core migration is complete and the data is
verified restored.** Three non-core tail items remain (below).

Related docs: design/plan in `docs/superpowers/{specs,plans}/2026-07-21-nixos-migration-backup-restore*.md`;
node flake in `nixos/`; live per-step log (git-ignored) in `.superpowers/sdd/progress.md`.

---

## Cluster access (CHANGED — the old `cachyos-x8664` alias is gone)

| Node | SSH | Role | kubectl |
|---|---|---|---|
| cachyos | `ssh slowking@cachyos` (or `-i ~/.ssh/id_ed25519 slowking@192.168.1.31`) | control-plane | ✅ works here |
| tux | `ssh slowking@tux` (or `-i ~/.ssh/id_ed25519 slowking@192.168.1.25`) | agent (k3s node-name `registry.gentoo.lan`) | ❌ |

Note: `cachyos` has `jq` and `perl` but **no `python3`** — don't pipe kubectl output to python there.

- sudo password: `thanas24`. `~/.ssh/id_ed25519` (vboxuser@virtualbox) is an authorized admin key.
- Node OS changes deploy via (NOT Argo): `cd nixos && NIX_SSHOPTS="-i ~/.ssh/gentoo_deploy_ed25519" nixos-rebuild switch --flake .#<cachyos|tux> --target-host deploy@<ip> --use-remote-sudo`

## What is healthy (verified)

- Both nodes `Ready` (NixOS 25.11, kernel 6.12, k3s v1.34.5), perf CPU governor, `btop`, IPv6 off, lid-ignore.
- **Postgres** restored on **PG16**, CNPG "healthy", real DBs present: `authentik`, `gitea`, `pclub`.
- **Vault** unsealed (HA active/standby), 32/34 `VaultStaticSecret`s syncing.
- **Longhorn** 11+ volumes restored from the MinIO backup; both nodes reach the backup target.
- **Both Cloudflare tunnels** (`cloudflare`, `cloudflare-friend`) connected — public services reachable.
- authentik, minio, redis, loki, monitoring (recovering), ~82 pods Running.
- Backups retained on the workstation: velero `migration-full-2` (canonical) + Vault raft snapshot
  `~/migration-minio/vault-raft-20260722.snap`.

Quick health check:
```bash
ssh -i ~/.ssh/id_ed25519 slowking@192.168.1.31 \
  'kubectl get nodes; kubectl get pods -A | grep -vE "Running|Completed"; \
   kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | grep -v "Synced.*Healthy"'
```

---

## Remaining tail items (none affect core data)

### 1. Tailscale admin-UI ingresses → cascades to `gitea` → `cntdwn` + `programmingclub`

**✅ RESOLVED 2026-07-23.** All 8 proxies Running on clean base hostnames; gitea Healthy; cntdwn and
programmingclub left `Unknown`. Root cause below (the earlier "tailnet ACL" diagnosis was WRONG).

Every ingress reconcile fails with:
```
failed to provision: failed to create or get API key secret: input does not match format
```
`input does not match format` is **Go's `fmt.Sscanf` error**, not a Tailscale API error. In
`cmd/k8s-operator/sts.go` `provisionSecrets()`, after creating the per-replica Secrets, the operator
lists *every* Secret carrying the ingress's child-resource labels and parses an ordinal off each with
`fmt.Sscanf(secret.Name, hsvc.Name+"-%d", &ordinal)`. Any Secret whose name doesn't start with the
*current* headless-Service name aborts the whole reconcile before a StatefulSet is ever created.

Velero restored the **old cluster's** proxy Secrets (batch created `22:39:30`), but the new operator
generated headless Services with fresh random suffixes and its own Secrets (batch `22:41:0x`). So
each of the 8 ingresses has one live Secret + one orphan the ordinal parser chokes on:

| live (matches a Service) | orphan (restored, dead device) |
|---|---|
| `ts-longhorn-tailscale-4rdz4-0` | `ts-longhorn-tailscale-qnxtx-0` |

Verified NOT the cause: the OAuth client is valid and *can* mint keys with both `tag:k8s` and
`tag:k8s-operator` (tested directly against `POST /api/v2/tailnet/-/keys`, HTTP 200 with the
operator's exact payload); `client_id`/`client_secret` have no stray whitespace; no ingress sets a
`tailscale.com/tags` annotation.

**Fix** — re-key each orphan onto the live Service name with ordinal `-1`. Then `Sscanf` succeeds,
`ordinal (1) >= Replicas (1)`, and the operator's own scale-down path calls `DeleteDevice` on the
dead tailnet device and deletes the Secret — no manual tailnet API calls needed. The live `-0`
Secrets already contain a valid unused `AuthKey` (minted 22:41), so the proxies come straight up.
Script: `docs/superpowers/fix-tailscale-orphan-secrets.sh`.

This also clears the pre-existing hostname drift — `argocd`/`grafana`/`minio` proxies were squatting
`-1` suffixed names (`argocd-argocd-tailscale-1`) instead of the base names the ingress `tls.hosts`
declare; deleting the dead devices frees them.

Once the proxies serve, **gitea** unblocks — its `configure-gitea` init container hard-fails on
`dial tcp 100.112.91.33:443: i/o timeout` reaching
`https://authentik-authentik-tailscale.tail27527e.ts.net/...openid-configuration` (100.112.91.33 is
the dead proxy). **cntdwn** and **programmingclub** then leave `Unknown` — they currently can't
render at all because their sources live in gitea (`502` on `git.thanaspapa.com/.../info/refs`).

### 2. zot internal registry → MinIO IAM is broken (`registry` + `minio`)

zot crash-loops on `S3: InvalidAccessKeyId`, but **zot's credentials are correct**: its
`AWS_ACCESS_KEY_ID` is the literal `zot` (matching `apps/minio/users.yaml`) and its
`AWS_SECRET_ACCESS_KEY` is byte-identical to `minio/minio-zot-credentials.secretKey`.

The real cause is one layer down — MinIO cannot decrypt its own config, so **it has no IAM users at
all**:
```
API: SYSTEM.config  Unable to initialize config, some features may be missing:
      madmin: invalid encryption algorithm ID
API: SYSTEM.iam     IAM sub-system is partially initialized, unable to write the IAM format:
      madmin: invalid encryption algorithm ID
```
The Vault key was **not** rotated and no data was lost. The actual bug was in this repo: the minio
chart mounts the `minio-kms` Secret at `/tmp/minio-config-env` and reads
`MINIO_CONFIG_ENV_FILE=/tmp/minio-config-env/config.env`, so the key only reaches the server if the
Secret contains a member literally named **`config.env`** holding env-file lines. The
`VaultStaticSecret` copied Vault's keys verbatim (`MINIO_KMS_SECRET_KEY`, `_raw`), so that file never
existed and MinIO ran with **no KMS at all** — hence it could not decrypt `.minio.sys/config`, IAM
never initialised, no users existed, and every S3 client got `InvalidAccessKeyId`.

**Fixed** in `apps/secrets/vault-sync/static-secrets.yaml` (commit `8f7884c`) by adding a
`destination.transformation` that synthesises `config.env`, plus `overwrite: true`:
```yaml
    transformation:
      excludeRaw: true
      templates:
        config.env:
          text: 'export MINIO_KMS_SECRET_KEY={{ get .Secrets "MINIO_KMS_SECRET_KEY" }}'
```
Recovery performed: moved the undecryptable `.minio.sys/config` aside, confirmed MinIO reinitialised,
then — once `config.env` was in place — restored the *original* config back. MinIO decrypted it
cleanly, the original users (`loki`/`postgres`/`zot`) came back and the SSE-encrypted objects list
and read fine. **All ~7.9G intact** (`loki` 1.5G, `postgres-backups` 5.6G, `zot` 804M). The Argo
`minio` sync then succeeded (the post-job's `encrypt set sse-s3` needs a working KMS).

Two throwaway copies are left on the volume and can be deleted once you're happy:
`/export/.minio.sys/config.broken-*` (the original, pre-recovery) and `config.nokms-*` (the
short-lived KMS-less one).

Diagnostic note: `mc ls local/zot` returning `Unable to list folder. KMS not configured` is the
tell that objects are SSE-encrypted and the server has no KMS — not that the data is gone.

### 2b. Stale traefik ClusterIP broke every `*.gentoo.lan` name

Surfaced only after the S3 failure cleared: zot then panicked on
`Get "https://sso.gentoo.lan/...": dial tcp 10.43.187.55:443: connect: connection refused`.

`10.43.187.55` was the **old cluster's** `svc/traefik` ClusterIP, hardcoded in
`apps/security-baseline/coredns-custom.yaml` and `apps/gitea-runners/runner.yaml` (`hostAliases`).
The rebuild moved traefik to `10.43.117.63`, silently pointing `sso`/`git`/`registry.gentoo.lan` at
a dead IP. Both files re-pinned in commit `8f7884c`.

**A ClusterIP is only stable for the life of a cluster — re-pin both files after any rebuild:**
```bash
kubectl -n kube-system get svc traefik -o jsonpath='{.spec.clusterIP}'
```
A rebuild-proof alternative is to use the node IPs (`192.168.1.31`/`.25`), which traefik's svclb also
serves on :443 and which the NixOS flake pins.

Cascades off zot: **gitea-runner**, **cntdwn** and **programmingclub** all `ImagePullBackOff` on
`registry.gentoo.lan/...` (they need zot, *not* gitea — the original handoff had this wrong), and the
two unsynced `VaultStaticSecret`s `argocd/zot-pull` + `argocd/argocd-image-updater-gitea`.

### 2c. Nodes trust a stale `gentoo-internal-ca` → all `registry.gentoo.lan` pulls fail

Surfaced last, once zot was actually serving. kubelet/containerd on both nodes:
```
failed to resolve reference "registry.gentoo.lan/infra/gitea-runner-tools:0.3.0":
tls: failed to verify certificate: x509: certificate signed by unknown authority
(possibly because of "x509: ECDSA verification failure" while trying to verify
 candidate authority certificate "gentoo-internal-ca")
```
The rebuild regenerated cert-manager's self-signed root, but the nodes pin a **checked-in copy** of
the old one — `nixos/assets/gentoo-internal-ca.crt`, deployed to
`/etc/rancher/k3s/certs/gentoo-internal-ca.crt` by `nixos/modules/k3s-common.nix` and referenced from
`nixos/assets/registries.yaml`. Same CN, different key, hence the confusing "ECDSA verification
failure" rather than a plain unknown-authority error.

| | fingerprint (SHA256, first bytes) | notBefore |
|---|---|---|
| live (cert-manager secret `cert-manager/gentoo-internal-ca`) | `7C:A7:7C:2B…` | Jul 22 2026 |
| pinned on nodes / in repo (stale) | `70:2C:55:AC…` | May 21 2026 |

Asset refreshed from the live secret. **This is a node-level change — Argo does not deploy it.**
Apply on *each* node (needs the interactive sudo password):
```bash
sudo nixos-rebuild switch --flake 'github:Slowbro213/homelab?dir=nixos#cachyos'   # on cachyos
sudo nixos-rebuild switch --flake 'github:Slowbro213/homelab?dir=nixos#tux'       # on tux
```
Re-capture the asset any time the CA changes:
```bash
kubectl -n cert-manager get secret gentoo-internal-ca -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > nixos/assets/gentoo-internal-ca.crt
```

⚠️ **Recurring footgun.** The `gentoo-internal-ca` Certificate in
`apps/cert-manager/internal-issuers.yaml` sets no `duration`/`renewBefore`, so it takes cert-manager's
90-day default and rotates roughly every 60 days (this one expires **Oct 20 2026**). Every rotation
silently re-breaks node→registry image pulls until the asset is re-captured and both nodes are
rebuilt. Worth giving the root an explicit long life, e.g.:
```yaml
spec:
  duration: 87600h     # 10 years
  renewBefore: 720h    # 30 days
```
Do that as a *deliberate* change, not in the middle of a repair: editing it forces cert-manager to
reissue the root, which invalidates every leaf signed by the old CA (Postgres `serverTLSSecret`,
gitea's `SSL_MODE: verify-full` DB connection, …) until those leaves are re-issued — and the node
asset then has to be re-captured and redeployed again anyway.

### 2d. Argo CD UI infinite redirect loop — ✅ RESOLVED (not in git, see warning)

`https://argocd-argocd-tailscale.tail27527e.ts.net/` returned `307` to *itself* — an infinite
redirect loop (`curl` exit 47, too many redirects), so the UI never loaded.

argocd-server was running in TLS mode behind the tailscale ingress, which terminates TLS and forwards
plain HTTP to `argocd-server:80`. The server saw a non-TLS request and 307-redirected to `https://`,
which came straight back through the same proxy. Fixed the standard way — serve plain HTTP behind the
TLS-terminating proxy:
```bash
kubectl -n argocd patch cm argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deploy/argocd-server
```
Verified: `HTTP 200`, 0 redirects, `<title>Argo CD</title>`. All 8 tailscale admin UIs return 200
(argocd, authentik, gitea, grafana, alertmanager, longhorn, minio, vault).

⚠️ **This change is not in git.** Argo CD is bootstrapped from the upstream pinned `install.yaml`
(`ARGOCD_INSTALL_URL`, see the migration plan) and is *not* self-managed by an `Application`, so
nothing reconciles it — that is also why the setting was silently lost when Argo CD was reinstalled
during the migration (stock `install.yaml` ships `argocd-cmd-params-cm` empty, so
`ARGOCD_SERVER_INSECURE` resolves to `""` → false). **Re-apply the patch above after any Argo CD
reinstall/upgrade from install.yaml**, or fold it into the bootstrap procedure.

### 3. prometheus / alertmanager — ✅ RESOLVED (verified 2026-07-23)

Root cause fixed in commit `f448557` (`prometheusOperator.tls.enabled=false`). All of
`prometheus-…-0`, `alertmanager-…-0`, the operator, grafana, kube-state-metrics and both
node-exporters are Running.

### 4. Cosmetic Argo drift (no action needed)

- `gitea` PVC `gitea-shared-storage` OutOfSync — spec matches the repo (20Gi / `longhorn-rwo`,
  Bound); the diff is leftover velero restore metadata.
- `kyverno-policies` (ClusterPolicies) and `nats` (StatefulSet) OutOfSync but Healthy — operator/
  admission-mutated defaults.

---

## Key fixes applied during the migration (committed `75285ea`, `6d3cd5c`, `f448557`)

Node OS / flake (`nixos/`):
- **sops circular dep**: `modules/sops.nix` must NOT manage the host key at
  `/etc/ssh/ssh_host_ed25519_key` — that key IS the age decryption key; managing it turns it into a
  dangling `/run/secrets` symlink at boot → nothing decrypts (no password, no WiFi PSK, no k3s token).
- `networking.enableIPv6 = false` — the WiFi LAN has no IPv6 route; containerd resolved `docker.io`
  to AAAA and image pulls failed "network unreachable".
- tux `services.logind.lidSwitch/ExternalPower = "ignore"` — closing the laptop lid suspended the
  node. Applying live needs `systemctl restart systemd-logind`; a prior lid-suspend also **drops the
  default route** (fix live with `systemctl restart network-setup.service`).
- `k3s --node-label=node.longhorn.io/create-default-disk=true` on both nodes — without it Longhorn
  creates no disk (`diskStatus: {}`), reports 0 capacity, and no PVC can schedule.
- `systemd.tmpfiles` symlink `/usr/local/{bin,sbin}/iscsiadm → /run/current-system/sw/bin/iscsiadm`
  — Longhorn runs `nsenter <host> iscsiadm` which needs it in the host PATH.
- perf CPU governor (`performance`) + disabled power daemons; added `btop`.

Cluster / Argo:
- Argo CD must be **≥ v3.1.0** (the repo's `Application`s use `spec.syncPolicy.automated.enabled`,
  which v3.0.x rejects under strict decoding). Bootstrapped v3.0.6, upgraded to v3.1.0.
- **Longhorn** `storageOverProvisioningPercentage: 200` — the sum of nominal PVC sizes exceeds one
  node's schedulable storage after the 30% reservation; actual data is far smaller.
- **velero CSI restore** scope MUST include the CSI CRDs, else all PVCs fail "VolumeSnapshot not found":
  `--include-resources namespaces,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io`
  (drop `persistentvolumes` — CSI provisions new PVs). Longhorn `longhorn-rwo` is WaitForFirstConsumer,
  so volume data restores when a workload first mounts the PVC.
- **Postgres**: pinned `spec.imageName: ghcr.io/cloudnative-pg/postgresql:16.10-standard-bookworm`
  (restored data is PG16; the operator default is PG18 and refuses incompatible data files). The CNPG
  webhook blocks a downgrade on an existing cluster, so the Cluster was deleted `--cascade=orphan`
  (PVCs + PVs=Retain + the velero backup are the safety nets) and recreated as PG16, which re-adopted
  the existing PVCs. Argo self-heal races cluster recreation — disable auto-sync on `cnpg-cluster`
  during the recreate.
- **Vault k8s auth after a cluster rebuild** returns 403 on login (old-cluster CA / token-reviewer JWT).
  Fix: `vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt token_reviewer_jwt=""
  disable_iss_validation=true`.

## Backup infrastructure (still live on the workstation)

- Throwaway MinIO = podman container `migration-minio` (**no restart policy** — `podman start
  migration-minio` after any workstation reboot; data in `~/migration-minio/data`). Reached over
  tailscale at `http://100.67.45.100:9000`; buckets `velero-metadata` + `longhorn-backups`; creds in
  the session scratchpad `minio-creds.env` (`MINIO_ACCESS_KEY=migration`). Also recoverable from live
  secrets `velero/velero-minio-credentials` and `longhorn-system/longhorn-backup-credential`.
- **Post-migration cleanup (plan Task 18, not yet done):** add a durable Velero `Schedule`, choose a
  durable backup target, then decommission the throwaway MinIO. `loki` history was intentionally
  dropped (disposable by chart design). `migration-full` (PartiallyFailed) can be deleted; keep
  `migration-full-2` until the durable schedule is proven.
