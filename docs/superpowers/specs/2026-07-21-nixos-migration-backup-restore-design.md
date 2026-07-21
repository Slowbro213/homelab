# NixOS Node Migration — Backup & Restore Design

Date: 2026-07-21

## Goal

Wipe both nodes of the "gentoo" k3s cluster (`cachyos-x8664` and `tux`) and reinstall
them on NixOS, without losing any cluster data. Both nodes go down and are reinstalled
together (full outage), not one at a time.

## Non-goals

- Designing the actual NixOS configuration/flake for either node (k3s module,
  partitioning, networking, users, etc.). That is a separate, later piece of work the
  user will handle themselves. This plan treats "install NixOS with k3s running" as an
  opaque step between backup and restore.
- Any live/rolling migration that keeps the cluster serving traffic during the OS swap.
  Both nodes are wiped together; the cluster is fully down for the duration.
- Redesigning the existing Argo CD app-of-apps structure, sync-wave ordering, or
  security-baseline policies — the rebuild relies on what's already encoded in this
  repo and doesn't change it.

## Constraints / facts established

- Every Longhorn-backed PVC currently has 2 healthy replicas, one per node — irrelevant
  to this plan since both nodes are wiped together (no surviving replica either way),
  but confirms all persistent data actually lives in Longhorn PVCs, not node-local paths
  outside Longhorn.
- `cachyos-x8664` is the sole control-plane node — no HA, so there's no way to avoid a
  hard cluster-down window regardless of approach.
- Vault uses Shamir seal (manual unseal, 5 keys / threshold 3) with raft storage,
  replicated across `vault-0` (tux) and `vault-1` (cachyos). The unseal keys and root
  token are **not** stored anywhere in the cluster and cannot be recovered from any
  backup taken here — the user has confirmed these are already saved externally
  (outside the cluster, prior to this plan).
- This repo's own git remote is GitHub, not the self-hosted Gitea instance — no circular
  dependency between "backing up Gitea's data" and "having this repo available to
  rebuild from."
- Longhorn currently has **no backup target configured** (`backup-target` setting is
  empty) — there is no existing backup capability to build on; this plan establishes one
  from scratch via Velero.
- Backup destination: a throwaway MinIO instance run on the user's main PC (NixOS, same
  LAN, not a cluster node) — reachable over the network, survives both nodes being wiped.

## Approaches considered

1. **Longhorn native backup/restore only.** Simplest, no new components, but restoring
   each of the ~14 PVCs to the exact PVC name/namespace each app expects is a manual,
   per-volume step with no automatic reattachment of the owning Kubernetes objects.
2. **Velero + Longhorn CSI snapshot integration (chosen).** Velero captures both the
   Kubernetes object state (PVCs, PVs, namespaces) and orchestrates the underlying
   Longhorn volume backup via the CSI snapshot integration, targeting Longhorn's backup
   store. A single `velero restore create` recreates PVCs/PVs bound to restored data
   automatically, avoiding manual per-volume bookkeeping. Costs slightly more setup than
   option 1. Chosen because the user explicitly preferred less manual restore work over
   less setup, and because it leaves a real ongoing backup capability in place afterward
   (see below).
3. **Raw filesystem copy of Longhorn replica directories.** Rejected — bypasses
   Longhorn's snapshot/consistency mechanism entirely; the on-disk replica layout is
   tied to Volume/Replica CRs that won't exist after the wipe, so files copied back
   don't cleanly reattach.

## Design

### Phase 1 — Backup target (main PC, before touching the cluster)

Stand up a throwaway MinIO instance on the user's main PC (NixOS, LAN-reachable, not a
cluster node). This single endpoint serves as:
- Velero's `BackupStorageLocation` (Kubernetes object manifests), and
- Longhorn's backup target (volume data), via the CSI snapshot integration's backing
  store, in a separate bucket from Velero's own bucket.

No changes to either cluster node are needed for this phase.

### Phase 2 — Quiesce and back up (cluster still running)

1. Add Velero to the cluster as a normal Argo CD `Application` (declarative, not a
   one-off `helm install`), configured with the Longhorn CSI snapshot integration
   pointed at the MinIO target from Phase 1.
2. Scale the stateful workloads to 0 replicas before backing up: Postgres/CNPG, Vault,
   Gitea, in-cluster MinIO, Grafana, Loki, NATS. Since the cluster is coming down for
   the migration regardless, quiescing before the backup (rather than relying on
   crash-consistent snapshots of live databases) costs nothing and removes an entire
   class of "was the backup actually consistent" risk.
3. Independently of Velero/Longhorn, run `vault operator raft snapshot save` and copy
   the resulting file directly to the main PC. This is belt-and-suspenders for the one
   dataset (Vault) where correctness matters most and where Vault's own
   application-level snapshot tooling is more trustworthy than a generic volume
   snapshot of a live raft store.
4. Trigger a Velero backup covering all namespaces. Confirm completion status **and**
   verify the backed-up data actually landed in the MinIO bucket on the main PC (not
   just a "Completed" `Backup` object status in-cluster).

### Phase 3 — Wipe (out of scope)

NixOS gets installed on both `cachyos-x8664` and `tux`. Handled entirely outside this
plan.

### Phase 4 — Rebuild

1. Fresh k3s on both NixOS nodes (out of scope how — see Non-goals). Manually bootstrap
   Argo CD once (mirroring however the cluster was originally bootstrapped), pointed at
   `clusters/gentoo/root-app.yaml`.
2. Let infra sync in the sync-wave order already encoded in the repo (namespaces /
   security-baseline → cert-manager → Longhorn → CNPG operator → ...). No changes needed
   to existing `sync-wave` annotations.
3. Once Longhorn reports healthy, re-add Velero and point it at the same MinIO
   backup-target bucket from Phase 1.
4. Run `velero restore create`, scoped explicitly to
   `--include-resources persistentvolumeclaims,persistentvolumes,namespaces` — not the
   full backup contents. Deployments/StatefulSets/Services etc. come from git via Argo
   CD; restoring them from Velero too would create two owners fighting over the same
   objects.
5. Let the remaining Argo CD Applications sync normally now that their PVCs are
   pre-populated with restored data.
6. Unseal both Vault pods (3-of-5 keys, from the externally-stored keys) once Vault's
   restored PVC and pod are up. Nothing depending on fresh Vault secrets (VaultStaticSecret
   syncs, cert-manager's Vault issuer if applicable, etc.) works until this is done.

### Phase 5 — Verify

- `kubectl get nodes` — both `Ready`.
- Longhorn volumes — all `healthy`, replica count back to 2/2 (once both nodes have
  rejoined and Longhorn has re-established replicas).
- `kubectl get applications -n argocd` — all `Synced`/`Healthy` (aside from any
  pre-existing exceptions noted at migration time).
- Vault — both pods unsealed, HA active/standby re-established.
- Spot-check actual data, not just pod/PVC status: a known Gitea repo is present and
  cloneable, a Grafana dashboard/history exists, a Postgres query against known data
  returns expected rows, MinIO buckets have expected object counts.

## Side effect worth keeping

The cluster currently has no backup target configured at all. This plan leaves Velero
wired up as a real, ongoing scheduled-backup capability (via a Velero `Schedule`
resource) rather than a one-time migration tool to be torn down afterward — a net
improvement to the cluster's resilience beyond just enabling this migration.

## Resolved facts (gathered from the live cluster, 2026-07-21)

- **Versions:** Longhorn `v1.11.1`; k8s `v1.36.0+k3s` on the control-plane (`cachyos`),
  `v1.35.5+k3s1` on the agent (`registry.gentoo.lan`). Pin Velero/plugin versions and
  the `VolumeSnapshotClass` against these.
- **Snapshot-CRD gap (must be fixed first):** the upstream external-snapshotter CRDs
  (`volumesnapshots.snapshot.storage.k8s.io`, `volumesnapshotcontents…`,
  `volumesnapshotclasses…`) and the snapshot-controller are **not installed** — only
  `snapshots.longhorn.io` (Longhorn-internal) and `etcdsnapshotfiles.k3s.cattle.io`
  exist. Longhorn's `csi-snapshotter` sidecar is running, but Velero's CSI integration
  needs the upstream CRDs + a Longhorn `VolumeSnapshotClass` with `type: bak` to route
  snapshots through the backup target. Phase 2 step 1 must install these before the
  first backup.
- **PVC → workload map to quiesce (14 PVCs, Phase 2 step 2):**
  - `databases`: `postgres-ha-1/2/3` — CNPG `Cluster/postgres-ha` (3 instances); quiesce
    via CNPG hibernate, not raw scale.
  - `vault`: `data-vault-0/1`, `audit-vault-0/1` — StatefulSet `vault` (2 replicas).
  - `gitea`: `gitea-shared-storage` — Deployment `gitea`.
  - `minio`: `minio` — Deployment `minio`.
  - `logging`: `storage-loki-0` — StatefulSet `loki`.
  - `monitoring`: `prometheus-…-prometheus-0`, `alertmanager-…-alertmanager-0` —
    StatefulSets.
  - `redis`: `redis-data-redis-master-0` — StatefulSet `redis-master`.
  - `programmingclub`: `programmingclub-uploads` — app Deployment (source in its own repo).
- **Argo CD bootstrap (Phase 4 step 1):** apply the pinned upstream Argo CD install
  manifest (`kubectl apply -n argocd -f <pinned install.yaml>`), then apply
  `clusters/gentoo/root-app.yaml`. (Argo CD's own install config is not tracked in this
  repo; accepted.)

## Still open for the implementation plan

- Exact pinned versions of the external-snapshotter CRDs/controller, Velero chart +
  Longhorn/CSI plugin, and the specific Argo CD `install.yaml` release tag — pin at
  implementation time against the versions above.
