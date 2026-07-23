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

### 1. Tailscale admin-UI ingresses → cascades to `gitea` → `cntdwn` + `programmingclub`  ⟵ biggest item

**Root cause found 2026-07-23 (the earlier "tailnet ACL" diagnosis below was WRONG).**

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
The PVC genuinely holds the restored original data (`/export/.minio.sys/config/config.json` dated
May 19, `iam/` dated Jul 15, buckets `loki` / `postgres-backups` / `zot`). `minio-kms` *did* sync
from Vault (`secret/minio/kms`), so the `MINIO_KMS_SECRET_KEY` now in the cluster is simply **not the
key that encrypted this data** — despite Vault being restored from the raft snapshot. Note the
warning already in `apps/minio/values.yaml`: rotating this key without migration makes old
ciphertext undecryptable.

**Resume — in order:**
1. Check Vault KV-v2 version history for the key; if an older version exists, roll back to it.
   ```bash
   vault kv metadata get secret/minio/kms      # how many versions, when written
   vault kv get -version=<N> secret/minio/kms
   ```
   This is the clean fix and preserves the SSE-S3 encrypted objects.
2. Only if the original key is unrecoverable: move `.minio.sys/config` aside so MinIO reinitialises,
   then re-run the chart's provisioning hook to recreate users/policies/buckets. SSE-S3 *objects*
   stay undecryptable — acceptable for `zot` (disposable CI cache) and `loki` (already written off),
   but `postgres-backups` would need re-seeding from a fresh backup.

Cascades off this: **gitea-runner** `ImagePullBackOff` on
`registry.gentoo.lan/infra/gitea-runner-tools:0.3.0` (it needs zot, *not* gitea — the earlier
handoff had this wrong), and the two unsynced `VaultStaticSecret`s `argocd/zot-pull` +
`argocd/argocd-image-updater-gitea`.

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
