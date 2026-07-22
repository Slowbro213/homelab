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
| cachyos | `ssh -i ~/.ssh/id_ed25519 slowking@192.168.1.31` | control-plane | ✅ works here |
| tux | `ssh -i ~/.ssh/id_ed25519 slowking@192.168.1.25` | agent (k3s node-name `registry.gentoo.lan`) | ❌ |

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

### 1. Tailscale admin-UI ingresses → cascades to `gitea` + `gitea-runner`  ⟵ biggest item, needs Tailscale-side action

The tailscale operator is running and the `tailscale/operator-oauth` secret is well-formed
(restored from backup: `client_id` 17 chars, `client_secret` `tskey-client…` 64 chars), tags are
valid (`OPERATOR_INITIAL_TAGS=tag:k8s-operator`, `PROXY_TAGS=tag:k8s`), and the OAuth token is NOT
revoked. Yet every ingress fails:
```
failed to create or get API key secret: input does not match format
```
This is a **tailnet-side authorization** issue: the OAuth client must be authorized (via `tagOwners`
in the tailnet ACL policy) to create devices/keys with **both** `tag:k8s` and `tag:k8s-operator`.

**Resume:** In the Tailscale admin console, verify the OAuth client's tags/ACL cover both tags (or
create a fresh OAuth client scoped to `Devices: write` with those tags). If new creds:
```bash
kubectl -n tailscale create secret generic operator-oauth \
  --from-literal=client_id='<id>' --from-literal=client_secret='<tskey-client-...>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n tailscale rollout restart deploy/operator
```
Once tailscale ingresses serve, **gitea** unblocks (its init configures the authentik OIDC provider
via a tailscale URL and currently times out), and **gitea-runner** follows.
Alternative: make gitea's OIDC-config init step non-fatal so gitea starts regardless.

### 2. zot internal registry (`registry` namespace) — CI image cache only

Crash-loops on `S3: InvalidAccessKeyId`. zot stores its data in the in-cluster MinIO (S3), and its
Vault-provided access key (`zot-s3-credentials`) doesn't match a MinIO user.

**Resume:** reconcile the MinIO user with zot's key:
```bash
# read zot's key
kubectl -n registry get secret zot-s3-credentials -o yaml
# create the matching user + policy on the in-cluster minio (via mc), or align the Vault key
# with an existing MinIO user.
```

### 3. prometheus / alertmanager — should be green now

Root cause fixed (commit `f448557`): the operator mounted a non-existent admission-webhook cert
because `admissionWebhooks.enabled=false` but `prometheusOperator.tls.enabled` defaulted true. Set
`prometheusOperator.tls.enabled=false` in `clusters/gentoo/apps/infra/monitoring.yaml`. The operator
came up and spawned prometheus+alertmanager (initializing at handoff). **Verify they reached Ready.**

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
