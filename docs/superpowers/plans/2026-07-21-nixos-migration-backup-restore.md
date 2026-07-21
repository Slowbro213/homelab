# NixOS Node Migration — Backup & Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## ⏱️ Execution status (updated 2026-07-21) — RESUME AT PART B

**Part A (Tasks 1–8, the backup capability): ✅ COMPLETE, deployed to `main`, verified green on the live cluster.**
Proof-backup of the `redis` namespace landed real data in both MinIO buckets; final review clean (no Critical/Important). Live state: Velero `1/1 Running`, BackupStorageLocation `Available`, `VolumeSnapshotClass longhorn-backup` present, Longhorn backup target `available: true`. Commits: `0e29d27` → `b9ef833`.

**Parts B–D (Tasks 9–18, the outage runbook): ⏳ NOT STARTED — user-driven, irreversible.** Resume here. Needs the user present, their externally-stored Vault unseal keys, and the physical NixOS installs. Do NOT auto-run.

**How the live implementation diverged from the task text below (reconcile before executing):**
- **Backup endpoint is the workstation's TAILSCALE IP `http://100.67.45.100:9000`**, not a LAN IP — LAN 9000 is firewalled; tailscale is trusted and reachable from both nodes + pods (proven). All manifests already use this.
- **MinIO** is a podman container `migration-minio` on the workstation (data in `~/migration-minio/data`) with **no restart policy** — re-run it after a reboot. Creds are not in git but recoverable from the cluster Secrets `velero/velero-minio-credentials` and `longhorn-system/longhorn-backup-credential`, or `podman inspect migration-minio`.
- **Velero** uses `upgradeCRDs: false` + full restricted-PSS security contexts (the cluster enforces the whole Kyverno restricted pack; the chart's `velero-upgrade-crds` Job is un-securable). Argo applies Velero's 13 CRDs itself.
- **Longhorn** backup target is set via the chart's `defaultBackupStore` key (v1.11 ignores `defaultSettings.backupTarget`).
- **VolumeSnapshotClass** `longhorn-backup` lives in `apps/snapshot-controller/` (wired into that kustomization), not `apps/velero/`.
- The two operator-applied credential Secrets already exist on the cluster; for the real backup/restore they must be re-applied if the cluster is rebuilt (Task 14 covers this).

Detailed per-task ledger (git-ignored, on-disk): `.superpowers/sdd/progress.md`.

---

**Goal:** Back up all persistent cluster state to a throwaway MinIO on the main PC, wipe both nodes to NixOS, then rebuild the cluster from git + restore the data — losing nothing.

**Architecture:** Velero captures Kubernetes object metadata (PVCs/PVs/namespaces) into one MinIO bucket; Longhorn's CSI snapshot integration (`VolumeSnapshotClass` with `type: bak`) uploads the actual volume data to Longhorn's own backup target in a second MinIO bucket. Velero runs **server-only (no privileged node-agent/datamover)** because volume data travels via Longhorn, not via Velero's file-mover. Backup capability is added declaratively as Argo CD `Application`s; the backup/restore *executions* are operator runbook commands. Restore is scoped to `pvc,pv,namespaces` only — all Deployments/StatefulSets/Services come back from git via Argo CD.

**Tech Stack:** k3s (server v1.36.0, agent v1.35.5), Longhorn v1.11.1, Argo CD (app-of-apps), Velero + built-in CSI, kubernetes-csi/external-snapshotter, MinIO (throwaway, on main PC), Vault (Shamir/raft), CNPG.

## Global Constraints

- **Every commit to `main` is an immediate deploy** — Argo CD auto-syncs. Nothing is applied "later."
- New `Application`s must reference an existing `AppProject` (`infra` here) whose `sourceRepos`/`destinations` already permit the repo + namespace, or the sync is rejected.
- New namespaces need: an entry in `apps/security-baseline/namespaces.yaml`, a default-deny + allow `NetworkPolicy` set in `apps/security-baseline/network-policies/`, and both wired into `apps/security-baseline/kustomization.yaml`.
- Kyverno denies `:latest` image tags and bare `type: LoadBalancer` Services — all pinned tags, no LoadBalancers here.
- Container requests small + explicit (~10–100m CPU, ~16–256Mi memory), memory-only limit, **no CPU limit**.
- Real secret material is never committed. **Exception for this migration only:** the throwaway-MinIO credentials for Velero and Longhorn's backup target are operator-applied Secrets (created by hand at backup and restore time), because Vault is sealed during rebuild and cannot supply them. These are throwaway creds for a throwaway MinIO; they are still never committed to git.
- No `Co-Authored-By` / attribution trailer on commits in this repo.
- Validate YAML before committing: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" <file>`.
- `kubectl` runs from `ssh slowking@cachyos-x8664` (no sudo, no KUBECONFIG export). `vault` CLI / raft snapshot runs against a Vault pod. The agent node `tux` has no usable kubectl.
- **If the `velero` CLI is not installed on `cachyos-x8664`,** every `velero <cmd>` below can be run inside the pod instead: `kubectl -n velero exec deploy/velero -- /velero <cmd>`. Likewise, if `kubectl cnpg` (the CNPG plugin) is missing, use the annotation fallback shown alongside each hibernate command.

## Migration Variables

Set these once before starting; every command below references them. These are operator-supplied inputs, not placeholders.

| Variable | Meaning | Example |
|---|---|---|
| `PC_HOST` | Main PC LAN IP/hostname running throwaway MinIO (NixOS, not a cluster node) | `192.168.1.10` |
| `PC_MINIO_PORT` | MinIO S3 API port on the PC | `9000` |
| `PC_MINIO_URL` | `http://$PC_HOST:$PC_MINIO_PORT` | `http://192.168.1.10:9000` |
| `MINIO_ACCESS_KEY` | Throwaway MinIO access key | `migration` |
| `MINIO_SECRET_KEY` | Throwaway MinIO secret key | (generated) |
| `VELERO_BUCKET` | Bucket for Velero object metadata | `velero-metadata` |
| `LH_BUCKET` | Bucket for Longhorn volume backups | `longhorn-backups` |
| `VELERO_CHART_VER` | vmware-tanzu/velero Helm chart version (verify supports k8s 1.36 at execution time) | `8.7.2` |
| `SNAPSHOTTER_REF` | external-snapshotter release tag (verify supports k8s 1.35/1.36) | `v8.2.0` |
| `ARGOCD_INSTALL_URL` | Pinned upstream Argo CD install manifest (same version originally installed) | `https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.6/manifests/install.yaml` |

**Pre-flight:** at execution time confirm `VELERO_CHART_VER`, `SNAPSHOTTER_REF`, and `ARGOCD_INSTALL_URL` against current release notes and the running k8s version (`kubectl get nodes -o wide`). Bump if needed and record the chosen values here before proceeding.

---

# Part A — Establish backup capability (cluster still running, low risk)

Tasks 1–8 add Velero + snapshotting to the **live** cluster declaratively and verify it works, all before any outage.

### Task 1: Stand up throwaway MinIO on the main PC + create buckets

**Files:** none in this repo (runs on the PC).

**Interfaces:**
- Produces: a reachable S3 endpoint `$PC_MINIO_URL` with buckets `$VELERO_BUCKET` and `$LH_BUCKET`, and credentials `$MINIO_ACCESS_KEY`/`$MINIO_SECRET_KEY`.

- [ ] **Step 1: Start MinIO on the PC (rootless podman)**

```bash
mkdir -p ~/migration-minio/data
podman run -d --name migration-minio \
  -p ${PC_MINIO_PORT}:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER="${MINIO_ACCESS_KEY}" \
  -e MINIO_ROOT_PASSWORD="${MINIO_SECRET_KEY}" \
  -v ~/migration-minio/data:/data \
  quay.io/minio/minio:latest server /data --console-address ":9001"
```

- [ ] **Step 2: Confirm it is reachable from the cluster network**

Run (from `cachyos-x8664`): `curl -sf ${PC_MINIO_URL}/minio/health/ready && echo OK`
Expected: `OK` (proves the cluster nodes can reach the PC over the LAN — the whole plan depends on this).

- [ ] **Step 3: Create both buckets**

```bash
mc alias set mig "${PC_MINIO_URL}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}"
mc mb mig/${VELERO_BUCKET} mig/${LH_BUCKET}
mc ls mig
```
Expected: both `${VELERO_BUCKET}/` and `${LH_BUCKET}/` listed.

- [ ] **Step 4: No commit** — nothing in-repo changed.

---

### Task 2: Permit Velero in the `infra` AppProject

**Files:**
- Modify: `clusters/gentoo/apps/projects.yaml` (the `infra` AppProject: `sourceRepos` + `destinations`)

**Interfaces:**
- Produces: the `infra` project accepts the Velero Helm repo and the `velero` destination namespace, unblocking Tasks 5–7.

- [ ] **Step 1: Add the Velero Helm repo to `infra.spec.sourceRepos`**

Add this line to the `sourceRepos` list of the `infra` AppProject (after the nats-io line):

```yaml
    - https://vmware-tanzu.github.io/helm-charts
```

- [ ] **Step 2: Add the `velero` destination namespace to `infra.spec.destinations`**

Add to the `destinations` list of the `infra` AppProject:

```yaml
    - server: https://kubernetes.default.svc
      namespace: velero
```

- [ ] **Step 3: Validate YAML**

Run: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" clusters/gentoo/apps/projects.yaml`
Expected: no output (valid).

- [ ] **Step 4: Commit**

```bash
git add clusters/gentoo/apps/projects.yaml
git commit -m "argocd: allow velero chart repo and namespace in infra project"
```

---

### Task 3: Vendor external-snapshotter CRDs + snapshot-controller as an Argo Application

k3s does **not** ship the upstream `VolumeSnapshot` CRDs or a snapshot-controller (confirmed: only `snapshots.longhorn.io` exists). Velero's CSI path needs them. Vendor pinned manifests into the repo and sync them ahead of Longhorn's CSI usage.

**Files:**
- Create: `apps/snapshot-controller/crds/` (vendored CRD YAMLs)
- Create: `apps/snapshot-controller/controller/` (vendored controller + RBAC YAMLs)
- Create: `apps/snapshot-controller/kustomization.yaml`
- Create: `clusters/gentoo/apps/infra/snapshot-controller.yaml` (Argo Application)

**Interfaces:**
- Produces: cluster-registered `volumesnapshots/volumesnapshotcontents/volumesnapshotclasses.snapshot.storage.k8s.io` CRDs + a running `snapshot-controller` Deployment in `kube-system`. Task 4 depends on the `VolumeSnapshotClass` CRD existing.

- [ ] **Step 1: Fetch pinned CRDs and controller manifests into the repo**

```bash
cd apps/snapshot-controller
mkdir -p crds controller
BASE="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_REF}"
for f in snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
         snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
         snapshot.storage.k8s.io_volumesnapshots.yaml; do
  curl -sfL "${BASE}/client/config/crd/${f}" -o "crds/${f}"
done
curl -sfL "${BASE}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" -o controller/rbac-snapshot-controller.yaml
curl -sfL "${BASE}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml" -o controller/setup-snapshot-controller.yaml
cd -
```
Expected: 5 files fetched, non-empty.

- [ ] **Step 2: Write `apps/snapshot-controller/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# snapshot-controller upstream deploys into kube-system.
resources:
  - crds/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
  - crds/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
  - crds/snapshot.storage.k8s.io_volumesnapshots.yaml
  - controller/rbac-snapshot-controller.yaml
  - controller/setup-snapshot-controller.yaml
```

- [ ] **Step 3: Write `clusters/gentoo/apps/infra/snapshot-controller.yaml`**

Sync-wave `-6` sequences these CRDs **before Velero (`-4`), their first consumer**. (The live waves are cert-manager `-20`, longhorn `-15`, snapshot-controller `-6`, minio `-5`, velero `-4`. Longhorn creates no `VolumeSnapshot` objects at install, so ordering vs Longhorn is irrelevant — only "CRDs before Velero" matters, and `-6 < -4` satisfies it.)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: snapshot-controller
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-6"
spec:
  project: infra
  source:
    repoURL: https://github.com/Slowbro213/homelab.git
    targetRevision: HEAD
    path: apps/snapshot-controller
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

- [ ] **Step 4: Validate YAML for the new manifests**

```bash
for f in apps/snapshot-controller/kustomization.yaml clusters/gentoo/apps/infra/snapshot-controller.yaml; do
  python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$f"; done
echo VALID
```
Expected: `VALID`.

- [ ] **Step 5: Commit**

```bash
git add apps/snapshot-controller clusters/gentoo/apps/infra/snapshot-controller.yaml
git commit -m "infra: add external-snapshotter CRDs + snapshot-controller (velero CSI prereq)"
```

- [ ] **Step 6: Confirm sync on the live cluster**

Run: `ssh slowking@cachyos-x8664 'kubectl get crd | grep volumesnapshot; kubectl -n kube-system get deploy snapshot-controller'`
Expected: three `volumesnapshot*.snapshot.storage.k8s.io` CRDs and `snapshot-controller` `1/1` (or `2/2`) Available.

---

### Task 4: Add the Longhorn `VolumeSnapshotClass` (type: bak) + Velero values dir

Routes CSI snapshots through Longhorn's **backup store** (not local-only snapshots).

**Files:**
- Create: `apps/snapshot-controller/volumesnapshotclass.yaml` (co-located with the CRDs/controller so the existing `snapshot-controller` Application applies it — the class needs those CRDs registered first, and no Application applies loose files under `apps/velero/`)
- Modify: `apps/snapshot-controller/kustomization.yaml` (add the class to `resources:`)
- Create: `apps/velero/values.yaml` (used by Task 7)

**Interfaces:**
- Produces: a `VolumeSnapshotClass` named `longhorn-backup` with `driver: driver.longhorn.io`, `parameters.type: bak`, synced by the `snapshot-controller` Application (sync-wave `-6`, before Velero at `-4`). Task 7's Velero backup references this class by its `velero.io/csi-volumesnapshot-class` label; Task 11 uses it.

- [ ] **Step 1: Write `apps/snapshot-controller/volumesnapshotclass.yaml`**

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-backup
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Retain
parameters:
  # "bak" makes the CSI snapshot create a Longhorn *backup* in the configured
  # backupTarget (the PC MinIO), which is what survives a full node wipe.
  type: bak
```

- [ ] **Step 1b: Add it to `apps/snapshot-controller/kustomization.yaml`**

Append to the existing `resources:` list (after the five CRD/controller entries):

```yaml
  - volumesnapshotclass.yaml
```

- [ ] **Step 2: Write `apps/velero/values.yaml`** (Velero Helm values — server-only, CSI on, node-agent off)

```yaml
# vmware-tanzu/velero Helm values. Volume data moves via Longhorn's backupTarget,
# so Velero needs NO node-agent/datamover — only its controller + CSI feature.
image:
  repository: velero/velero
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.11.1
    volumeMounts:
      - mountPath: /target
        name: plugins

# Built-in CSI support (Velero >=1.14); no separate CSI plugin image needed.
features: EnableCSI
deployNodeAgent: false
snapshotsEnabled: true

configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero-metadata   # keep in sync with $VELERO_BUCKET
      default: true
      config:
        region: minio-default
        s3ForcePathStyle: "true"
        s3Url: http://REPLACE_PC_MINIO_URL   # set to $PC_MINIO_URL at execution time
  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: minio-default

credentials:
  useSecret: true
  existingSecret: velero-minio-credentials   # operator-applied (Task 6), NOT from Vault

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 512Mi

# No scheduled backups yet; the Schedule is added in Task 18 after restore is proven.
schedules: {}
```

- [ ] **Step 3: Validate YAML**

```bash
for f in apps/snapshot-controller/volumesnapshotclass.yaml apps/snapshot-controller/kustomization.yaml apps/velero/values.yaml; do
  python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$f"; done
echo VALID
```
Expected: `VALID`. (In this environment `python3` lacks `yaml`; use `nix-shell -p python3Packages.pyyaml --run "python3 -c \"import yaml; list(yaml.safe_load_all(open('<FILE>')))\""` per file instead.)

- [ ] **Step 4: Commit**

```bash
git add apps/snapshot-controller/volumesnapshotclass.yaml apps/snapshot-controller/kustomization.yaml apps/velero/values.yaml
git commit -m "velero: add longhorn-backup VolumeSnapshotClass and helm values"
```

Note: `apps/velero/values.yaml` still has `REPLACE_PC_MINIO_URL` / bucket to reconcile with `$PC_MINIO_URL` and `$VELERO_BUCKET`. Set the real values in this same commit (the example uses the defaults from the Migration Variables table).

---

### Task 5: security-baseline for the `velero` namespace

**Files:**
- Modify: `apps/security-baseline/namespaces.yaml` (add `velero` namespace)
- Create: `apps/security-baseline/network-policies/velero.yaml`
- Create: `apps/security-baseline/resource-limits/velero.yaml`
- Modify: `apps/security-baseline/kustomization.yaml` (wire both in)

**Interfaces:**
- Consumes: nothing.
- Produces: a `velero` namespace with `baseline` PSS (Velero server needs slightly more than `restricted`; node-agent is off so `baseline` suffices), default-deny NetworkPolicy plus egress to DNS, the kube-apiserver, and the PC MinIO.

- [ ] **Step 1: Add the `velero` namespace block to `apps/security-baseline/namespaces.yaml`**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: velero
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

- [ ] **Step 2: Write `apps/security-baseline/network-policies/velero.yaml`**

`$PC_HOST/32` below must be the PC's LAN IP with a `/32` suffix (e.g. `192.168.1.10/32`).

```yaml
# ============================================================
# Namespace: velero
# ============================================================
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: velero
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-velero-egress
  namespace: velero
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # kube-apiserver (k3s serves it on the node IP:6443) + in-cluster ClusterIP 443
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 6443
        - protocol: TCP
          port: 443
    # Throwaway MinIO on the PC (object metadata upload)
    - to:
        - ipBlock:
            cidr: REPLACE_PC_HOST/32
      ports:
        - protocol: TCP
          port: 9000   # keep in sync with $PC_MINIO_PORT
```

- [ ] **Step 3: Write `apps/security-baseline/resource-limits/velero.yaml`**

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: velero-defaults
  namespace: velero
spec:
  limits:
    - type: Container
      default:
        memory: 512Mi
      defaultRequest:
        cpu: 50m
        memory: 128Mi
```

- [ ] **Step 4: Wire both into `apps/security-baseline/kustomization.yaml`**

Add to `resources:` — a network-policies entry and a resource-limits entry:

```yaml
  - network-policies/velero.yaml
  - resource-limits/velero.yaml
```

- [ ] **Step 5: Validate all four files**

```bash
for f in apps/security-baseline/namespaces.yaml \
         apps/security-baseline/network-policies/velero.yaml \
         apps/security-baseline/resource-limits/velero.yaml \
         apps/security-baseline/kustomization.yaml; do
  python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$f"; done
echo VALID
```
Expected: `VALID`. (Also set the real `REPLACE_PC_HOST/32` and port before committing.)

- [ ] **Step 6: Commit**

```bash
git add apps/security-baseline/namespaces.yaml \
        apps/security-baseline/network-policies/velero.yaml \
        apps/security-baseline/resource-limits/velero.yaml \
        apps/security-baseline/kustomization.yaml
git commit -m "security-baseline: add velero namespace, netpol, and limitrange"
```

- [ ] **Step 7: Confirm the namespace synced**

Run: `ssh slowking@cachyos-x8664 'kubectl get ns velero -o jsonpath="{.metadata.labels}"; echo; kubectl -n velero get netpol,limitrange'`
Expected: `velero` namespace exists with baseline label, `default-deny` + `allow-velero-egress` NetworkPolicies, and the `velero-defaults` LimitRange present.

---

### Task 6: Configure Longhorn's backup target + operator-applied credentials

Volume data goes to Longhorn's backupTarget. Set the target declaratively in Longhorn's Helm values; supply its S3 credentials via an operator-applied Secret (Vault-independent, per Global Constraints).

**Files:**
- Modify: Longhorn's Helm values (the `valueFiles` referenced by `clusters/gentoo/apps/infra/longhorn.yaml` — inspect it first to find the exact values path)

**Interfaces:**
- Consumes: `$LH_BUCKET`, `$PC_MINIO_URL`, MinIO creds.
- Produces: Longhorn `backupTarget = s3://$LH_BUCKET@minio-default/` with credential Secret `longhorn-backup-credential` in `longhorn-system`. Task 11's `type: bak` snapshots land here.

- [ ] **Step 1: Inspect the Longhorn Application to find its values file**

Run: `sed -n '1,60p' clusters/gentoo/apps/infra/longhorn.yaml`
Expected: identifies whether values are inline (`helm.valuesObject`) or in `apps/longhorn/values.yaml`. Edit whichever it is in the next step.

- [ ] **Step 2: Set the default backup store in Longhorn values**

Add under `defaultSettings` (adjust to inline vs file form found in Step 1):

```yaml
defaultSettings:
  backupTarget: s3://longhorn-backups@minio-default/   # $LH_BUCKET
  backupTargetCredentialSecret: longhorn-backup-credential
```

- [ ] **Step 3: Validate + commit**

```bash
python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" <the longhorn values file>
git add <the longhorn values file>
git commit -m "longhorn: point backupTarget at throwaway PC MinIO bucket"
```

- [ ] **Step 4: Operator-apply the Longhorn backup credential Secret** (NOT committed)

```bash
ssh slowking@cachyos-x8664 "kubectl -n longhorn-system create secret generic longhorn-backup-credential \
  --from-literal=AWS_ACCESS_KEY_ID='${MINIO_ACCESS_KEY}' \
  --from-literal=AWS_SECRET_ACCESS_KEY='${MINIO_SECRET_KEY}' \
  --from-literal=AWS_ENDPOINTS='${PC_MINIO_URL}' \
  --dry-run=client -o yaml | kubectl apply -f -"
```

- [ ] **Step 5: Verify Longhorn accepted the target**

Run: `ssh slowking@cachyos-x8664 'kubectl -n longhorn-system get backuptarget default -o jsonpath="{.status.available}"; echo'`
Expected: `true` (Longhorn reached the PC MinIO). If `false`, check the credential Secret and `curl ${PC_MINIO_URL}/minio/health/ready` from the node.

---

### Task 7: Add Velero as an Argo CD Application + operator-applied MinIO credentials

**Files:**
- Create: `clusters/gentoo/apps/infra/velero.yaml` (Argo Application, Helm)

**Interfaces:**
- Consumes: `apps/velero/values.yaml` (Task 4), the `velero` namespace (Task 5), `infra` project permissions (Task 2).
- Produces: a running Velero server in `velero` with an `Available` `BackupStorageLocation`. Tasks 11 & 15 drive it.

- [ ] **Step 1: Operator-apply Velero's MinIO credential Secret** (NOT committed; Vault-independent)

```bash
cat > /tmp/velero-creds <<EOF
[default]
aws_access_key_id=${MINIO_ACCESS_KEY}
aws_secret_access_key=${MINIO_SECRET_KEY}
EOF
ssh slowking@cachyos-x8664 "kubectl -n velero create secret generic velero-minio-credentials \
  --from-file=cloud=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -" < /tmp/velero-creds
rm -f /tmp/velero-creds
```

- [ ] **Step 2: Write `clusters/gentoo/apps/infra/velero.yaml`**

Sync-wave `-4` = after longhorn (`-15`), snapshot-controller (`-6`), and minio (`-5`) so the Longhorn CSI driver, the snapshot CRDs/`VolumeSnapshotClass`, and the backup target all exist first.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-4"
spec:
  project: infra
  source:
    repoURL: https://vmware-tanzu.github.io/helm-charts
    chart: velero
    targetRevision: 8.7.2   # $VELERO_CHART_VER
    helm:
      releaseName: velero
      valueFiles:
        - $values/apps/velero/values.yaml
  sources:
    - repoURL: https://vmware-tanzu.github.io/helm-charts
      chart: velero
      targetRevision: 8.7.2   # $VELERO_CHART_VER
      helm:
        releaseName: velero
        valueFiles:
          - $values/apps/velero/values.yaml
    - repoURL: https://github.com/Slowbro213/homelab.git
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

- [ ] **Step 3: Validate + commit**

```bash
python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" clusters/gentoo/apps/infra/velero.yaml
git add clusters/gentoo/apps/infra/velero.yaml
git commit -m "infra: add velero Application (server-only, CSI, PC MinIO backend)"
```

---

### Task 8: Verify the backup capability on the live cluster

**Files:** none.

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: proof that a CSI backup actually lands in both MinIO buckets — the go/no-go gate before any outage.

- [ ] **Step 1: Confirm Velero + BSL healthy**

```bash
ssh slowking@cachyos-x8664 'kubectl -n velero get pods; kubectl -n velero get backupstoragelocation'
```
Expected: `velero-*` pod `Running`; BSL `default` PHASE `Available`.

- [ ] **Step 2: Confirm the VolumeSnapshotClass is registered**

Run: `ssh slowking@cachyos-x8664 'kubectl get volumesnapshotclass longhorn-backup'`
Expected: present, `driver.longhorn.io`.

- [ ] **Step 3: Dry-run a real backup of one small namespace to prove the whole path**

```bash
ssh slowking@cachyos-x8664 'velero backup create verify-redis --include-namespaces redis --snapshot-volumes --wait' \
  || ssh slowking@cachyos-x8664 'kubectl -n velero exec deploy/velero -- /velero backup create verify-redis --include-namespaces redis --snapshot-volumes --wait'
```
Expected: `Backup completed` / phase `Completed`.

- [ ] **Step 4: Verify data actually landed in BOTH buckets (not just in-cluster status)**

```bash
mc ls --recursive mig/${VELERO_BUCKET}/backups/verify-redis/
mc ls --recursive mig/${LH_BUCKET}/
```
Expected: Velero metadata objects under `backups/verify-redis/`, and Longhorn backup blocks/volume dirs under `${LH_BUCKET}`. If `${LH_BUCKET}` is empty, the `type: bak` routing is wrong — **stop and fix before proceeding** (this is the single most important check in Part A).

- [ ] **Step 5: Clean up the verification backup**

Run: `ssh slowking@cachyos-x8664 'velero backup delete verify-redis --confirm'`
Expected: deletion request submitted. Part A complete — the cluster now has a proven backup capability.

---

# Part B — Backup execution (start of the outage window)

Tasks 9–13 quiesce and capture everything. From here the cluster is going down.

### Task 9: Freeze Argo CD, then quiesce stateful workloads

`selfHeal: true` will revert manual scale-downs, so stop the Argo application-controller first.

**Files:** none (live operational commands).

**Interfaces:**
- Produces: all stateful workloads at 0 replicas / hibernated, so backups are consistent, not crash-consistent.

- [ ] **Step 1: Scale the Argo CD application-controller to 0 (stops reconciliation/self-heal)**

```bash
ssh slowking@cachyos-x8664 'kubectl -n argocd scale statefulset argocd-application-controller --replicas=0'
ssh slowking@cachyos-x8664 'kubectl -n argocd get statefulset argocd-application-controller'
```
Expected: `READY 0/0`. Argo will no longer fight manual changes.

- [ ] **Step 2: (Vault snapshot happens next in Task 10 — do NOT scale Vault down yet.)** Quiesce the non-Vault stateful workloads:

```bash
ssh slowking@cachyos-x8664 '
kubectl -n gitea scale deploy gitea --replicas=0
kubectl -n minio scale deploy minio --replicas=0
kubectl -n logging scale statefulset loki --replicas=0
kubectl -n monitoring scale statefulset prometheus-monitoring-kube-prometheus-prometheus --replicas=0
kubectl -n monitoring scale statefulset alertmanager-monitoring-kube-prometheus-alertmanager --replicas=0
kubectl -n redis scale statefulset redis-master --replicas=0
'
```
Expected: each scaled to 0.

- [ ] **Step 3: Hibernate the CNPG Postgres cluster (supported clean shutdown)**

```bash
ssh slowking@cachyos-x8664 'kubectl cnpg hibernate on postgres-ha -n databases' \
  || ssh slowking@cachyos-x8664 'kubectl annotate cluster postgres-ha -n databases cnpg.io/hibernation=on --overwrite'
```
Expected: `postgres-ha` instances terminate cleanly (PVCs retained). Verify: `kubectl -n databases get pods` shows no `postgres-ha-*` running.

- [ ] **Step 4: Confirm quiesced**

Run: `ssh slowking@cachyos-x8664 'kubectl get pods -A | grep -E "gitea|minio|loki|prometheus-|alertmanager-|redis-master|postgres-ha" | grep -v Completed'`
Expected: no `Running` pods for these workloads (Vault still up — intentional).

---

### Task 10: Vault raft snapshot (belt-and-suspenders), copied to the PC

**Files:** none.

**Interfaces:**
- Consumes: a running (unsealed) Vault + externally-stored root token.
- Produces: `vault-raft-<ts>.snap` on the PC — an application-level Vault backup independent of Velero/Longhorn.

- [ ] **Step 1: Take the raft snapshot from an unsealed Vault pod**

```bash
ssh slowking@cachyos-x8664 'kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=<root-token> vault operator raft snapshot save /tmp/vault.snap"'
ssh slowking@cachyos-x8664 'kubectl -n vault cp vault-0:/tmp/vault.snap /tmp/vault-raft.snap'
```
Expected: snapshot written (`ls -l /tmp/vault-raft.snap` non-zero on the node). Use the externally-stored root token; do not print it into logs unnecessarily.

- [ ] **Step 2: Copy it off the cluster to the PC**

```bash
scp slowking@cachyos-x8664:/tmp/vault-raft.snap ~/migration-minio/vault-raft-$(date +%Y%m%d).snap
```
Expected: file present on the PC, non-zero size.

- [ ] **Step 3: Now quiesce Vault too**

```bash
ssh slowking@cachyos-x8664 'kubectl -n vault scale statefulset vault --replicas=0'
```
Expected: `vault` `0/0`. All stateful workloads are now down.

---

### Task 11: Velero full backup (all namespaces, with volume snapshots)

**Files:** none.

**Interfaces:**
- Produces: a `Completed` Velero backup `migration-full` covering every namespace, with Longhorn `type: bak` backups of every PVC in `$LH_BUCKET`.

- [ ] **Step 1: Trigger the full backup**

```bash
ssh slowking@cachyos-x8664 'velero backup create migration-full --snapshot-volumes --wait'
```
Expected: phase `Completed`, `Errors: 0`. (Warnings about skipped/terminating pods are fine — pods are intentionally down.)

- [ ] **Step 2: Inspect for per-item errors**

Run: `ssh slowking@cachyos-x8664 'velero backup describe migration-full --details | sed -n "1,80p"'`
Expected: all 14 PVCs listed with CSI snapshots `Completed`. Confirm each namespace's PVCs appear (databases×3, vault×4, gitea, minio, logging, monitoring×2, redis, programmingclub).

---

### Task 12: Verify the backup is real and complete (go/no-go for the wipe)

**Files:** none.

**Interfaces:**
- Produces: the explicit gate — data confirmed durable on the PC before both nodes are wiped.

- [ ] **Step 1: Confirm Velero metadata objects in the PC bucket**

Run: `mc ls --recursive mig/${VELERO_BUCKET}/backups/migration-full/`
Expected: `velero-backup.json`, `*-volumesnapshots.json.gz`, `*-csi-volumesnapshotcontents.json.gz`, resource lists — non-empty.

- [ ] **Step 2: Confirm Longhorn volume backups in the PC bucket**

Run: `mc ls --recursive mig/${LH_BUCKET}/backupstore/volumes/ | head`
Expected: one backup path per PVC volume (`pvc-*`), each with block data. Count should reflect all 14 volumes.

- [ ] **Step 3: Confirm the Vault snapshot is on the PC** (from Task 10)

Run: `ls -l ~/migration-minio/vault-raft-*.snap`
Expected: present, non-zero.

- [ ] **Step 4: GATE.** Only proceed to Part C (wipe) if Steps 1–3 all pass. If any bucket is empty or a PVC is missing, re-run the relevant backup — do **not** wipe on a partial backup.

---

# Part C — Rebuild + restore (post-wipe; NixOS + fresh k3s already installed)

Phase 3 (NixOS install on both nodes) is out of scope. Resume here once both nodes are on NixOS with fresh k3s running and `kubectl get nodes` shows both `Ready`.

### Task 13: Bootstrap Argo CD and let infra sync

**Files:** none (operator commands; repo already holds all manifests).

**Interfaces:**
- Consumes: fresh k3s, this git repo.
- Produces: Argo CD reconciling the app-of-apps; infra syncing in sync-wave order (snapshot-controller `-6` → longhorn `-5` → velero `-4` → ...).

- [ ] **Step 1: Apply the pinned upstream Argo CD install manifest**

```bash
ssh slowking@cachyos-x8664 'kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -'
ssh slowking@cachyos-x8664 "kubectl apply -n argocd -f ${ARGOCD_INSTALL_URL}"
ssh slowking@cachyos-x8664 'kubectl -n argocd rollout status deploy/argocd-server --timeout=300s'
```
Expected: Argo CD components Running.

- [ ] **Step 2: Apply the app-of-apps root**

```bash
ssh slowking@cachyos-x8664 'kubectl apply -f https://raw.githubusercontent.com/Slowbro213/homelab/main/clusters/gentoo/root-app.yaml'
```
Expected: `application.argoproj.io/root created`.

- [ ] **Step 3: Let infra sync; watch until Longhorn is up (but expect stateful apps to be unhealthy — their PVCs are empty until restore)**

Run: `ssh slowking@cachyos-x8664 'kubectl -n longhorn-system get pods; kubectl get applications -n argocd'`
Expected: Longhorn `longhorn-manager` DaemonSet + CSI pods Running. Do **not** wait for gitea/vault/postgres to be Healthy yet — that comes after restore.

---

### Task 14: Re-establish backup credentials + confirm Velero/snapshot stack on the new cluster

Argo CD re-creates the Velero/snapshot-controller Applications and the Longhorn backupTarget setting from git, but the two Vault-independent credential Secrets are not in git and must be re-applied by the operator.

**Files:** none.

**Interfaces:**
- Produces: Longhorn + Velero both pointed at the same PC MinIO buckets, credentials present, ready to restore.

- [ ] **Step 1: Re-apply the Longhorn backup credential Secret** (same as Task 6 Step 4)

```bash
ssh slowking@cachyos-x8664 "kubectl -n longhorn-system create secret generic longhorn-backup-credential \
  --from-literal=AWS_ACCESS_KEY_ID='${MINIO_ACCESS_KEY}' \
  --from-literal=AWS_SECRET_ACCESS_KEY='${MINIO_SECRET_KEY}' \
  --from-literal=AWS_ENDPOINTS='${PC_MINIO_URL}' \
  --dry-run=client -o yaml | kubectl apply -f -"
```

- [ ] **Step 2: Re-apply the Velero MinIO credential Secret** (same as Task 7 Step 1)

```bash
cat > /tmp/velero-creds <<EOF
[default]
aws_access_key_id=${MINIO_ACCESS_KEY}
aws_secret_access_key=${MINIO_SECRET_KEY}
EOF
ssh slowking@cachyos-x8664 "kubectl -n velero create secret generic velero-minio-credentials \
  --from-file=cloud=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -" < /tmp/velero-creds
rm -f /tmp/velero-creds
```

- [ ] **Step 3: Confirm Longhorn sees the existing backups + Velero BSL is Available**

```bash
ssh slowking@cachyos-x8664 'kubectl -n longhorn-system get backuptarget default -o jsonpath="{.status.available}"; echo
kubectl -n velero get backupstoragelocation default
velero backup get'
```
Expected: backupTarget `available: true`, BSL `Available`, and `migration-full` visible in `velero backup get` (Velero read it back from the PC bucket). If `migration-full` is not listed, restart the Velero pod so it re-syncs the BSL, then re-check.

---

### Task 15: Restore PVCs/PVs/namespaces only

**Files:** none.

**Interfaces:**
- Consumes: `migration-full` backup.
- Produces: all 14 PVCs `Bound` to Longhorn volumes restored from the PC backups. Everything else (Deployments/StatefulSets/Services) is owned by Argo CD/git and must NOT be restored by Velero.

- [ ] **Step 1: Create the scoped restore**

```bash
ssh slowking@cachyos-x8664 'velero restore create migration-restore \
  --from-backup migration-full \
  --include-resources persistentvolumeclaims,persistentvolumes,namespaces \
  --wait'
```
Expected: phase `Completed`. (Restoring only PVC/PV/namespaces avoids two owners — Velero and Argo — fighting over Deployments/StatefulSets.)

- [ ] **Step 2: Watch PVCs bind as Longhorn restores volume data**

Run: `ssh slowking@cachyos-x8664 'kubectl get pvc -A'`
Expected: all 14 PVCs progress to `Bound`. Longhorn restores from `$LH_BUCKET` in the background; large volumes (minio 50Gi, gitea 20Gi) take longest. Confirm via `kubectl -n longhorn-system get volumes.longhorn.io` → `robustness: healthy` (or restoring → healthy).

- [ ] **Step 3: Verify no unexpected non-PVC resources were restored**

Run: `ssh slowking@cachyos-x8664 'velero restore describe migration-restore --details | grep -iE "restored|warnings" | head'`
Expected: only namespaces/PVCs/PVs restored; warnings about skipped cluster resources are expected and fine.

---

### Task 16: Re-enable Argo CD reconciliation, un-hibernate, unseal Vault

**Files:** none.

**Interfaces:**
- Produces: workloads rescheduled onto their now-populated PVCs; Vault unsealed so secret-dependent apps recover.

- [ ] **Step 1: Confirm the Argo application-controller is running on the new cluster**

Run: `ssh slowking@cachyos-x8664 'kubectl -n argocd get statefulset argocd-application-controller'`
Expected: `1/1`. (On a fresh bootstrap it starts at 1; the Task 9 scale-to-0 was on the old cluster and does not carry over. If for any reason it is 0, `kubectl -n argocd scale statefulset argocd-application-controller --replicas=1`.)

- [ ] **Step 2: Un-hibernate CNPG Postgres**

```bash
ssh slowking@cachyos-x8664 'kubectl cnpg hibernate off postgres-ha -n databases' \
  || ssh slowking@cachyos-x8664 'kubectl annotate cluster postgres-ha -n databases cnpg.io/hibernation=off --overwrite'
```
Expected: `postgres-ha-*` pods start and reach `Ready` against the restored PVCs.

- [ ] **Step 3: Let Argo self-heal replica counts back to git state**

Argo (with selfHeal) restores gitea/minio/loki/prometheus/alertmanager/redis/vault replica counts from git automatically now that reconciliation is on. Confirm:
Run: `ssh slowking@cachyos-x8664 'kubectl get pods -A | grep -E "gitea|minio|loki|prometheus-|redis-master|vault-" | head'`
Expected: pods scheduling/starting. Vault pods start but will be **sealed**.

- [ ] **Step 4: Unseal both Vault pods (3-of-5 externally-stored keys)**

```bash
for p in vault-0 vault-1; do
  for i in 1 2 3; do
    ssh slowking@cachyos-x8664 "kubectl -n vault exec $p -- vault operator unseal <key-$i>"
  done
done
ssh slowking@cachyos-x8664 'kubectl -n vault exec vault-0 -- vault status; kubectl -n vault exec vault-1 -- vault status'
```
Expected: both `Sealed: false`; one active, one standby (HA re-established). Until this, all `VaultStaticSecret` syncs and the cert-manager Vault issuer stay broken.

---

# Part D — Verify + keep the backup capability

### Task 17: Full verification checklist

**Files:** none.

**Interfaces:**
- Produces: sign-off that the migration succeeded end-to-end, including real data (not just pod/PVC status).

- [ ] **Step 1: Nodes + Longhorn health**

```bash
ssh slowking@cachyos-x8664 'kubectl get nodes -o wide
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness'
```
Expected: both nodes `Ready`; every volume `attached`/`healthy`, replica count back to 2/2 once both nodes rejoined.

- [ ] **Step 2: All Argo Applications reconciled**

Run: `ssh slowking@cachyos-x8664 'kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'`
Expected: all `Synced`/`Healthy` (aside from any pre-existing exceptions noted at migration time).

- [ ] **Step 3: Data spot-checks (the real test)**

```bash
# Postgres: a known table returns rows
ssh slowking@cachyos-x8664 'kubectl -n databases exec postgres-ha-1 -- psql -U postgres -c "\l"'
# Gitea: a known repo is present
ssh slowking@cachyos-x8664 'kubectl -n gitea exec deploy/gitea -- ls /data/git/repositories'
# MinIO: expected buckets/objects
ssh slowking@cachyos-x8664 'kubectl -n minio exec deploy/minio -- mc ls local || true'
# Vault: reads a known secret path
ssh slowking@cachyos-x8664 'kubectl -n vault exec vault-0 -- vault kv list <known-mount>'
```
Expected: known data present in each — not just running pods. Spot-check at least Postgres rows, a Gitea repo, MinIO object counts, and a Grafana dashboard (via its Tailscale UI).

---

### Task 18: Keep Velero as an ongoing scheduled backup

The cluster had no backup target before this. Leave a real scheduled backup behind (the design's "side effect worth keeping").

**Files:**
- Modify: `apps/velero/values.yaml` (add a `Schedule` via chart `schedules:`)

**Interfaces:**
- Consumes: the proven Velero stack.
- Produces: a daily Velero `Schedule` backing up all namespaces with volume snapshots.

- [ ] **Step 1: Replace `schedules: {}` in `apps/velero/values.yaml`**

```yaml
schedules:
  daily-full:
    disabled: false
    schedule: "0 3 * * *"
    useOwnerReferencesInBackup: false
    template:
      snapshotVolumes: true
      includedNamespaces:
        - "*"
      ttl: 168h0m0s   # keep 7 days
```

- [ ] **Step 2: Decide on a durable backup target.** The throwaway PC MinIO is not a permanent home. Either keep it (accept the risk) or repoint `apps/velero/values.yaml` BSL + Longhorn `backupTarget` at a durable bucket and re-apply both credential Secrets. Record the decision inline in `apps/velero/values.yaml` as a comment.

- [ ] **Step 3: Validate + commit**

```bash
python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" apps/velero/values.yaml
git add apps/velero/values.yaml
git commit -m "velero: add daily scheduled backup, keep as ongoing capability"
```

- [ ] **Step 4: Confirm the Schedule synced**

Run: `ssh slowking@cachyos-x8664 'kubectl -n velero get schedule'`
Expected: `daily-full` present with the `0 3 * * *` cron. Migration complete.

---

## Post-migration cleanup (optional)

- Stop/remove the throwaway MinIO on the PC **only after** confirming the durable target (Task 18 Step 2) works and a fresh scheduled backup has completed against it.
- The two operator-applied credential Secrets (`longhorn-backup-credential`, `velero-minio-credentials`) remain live-only (not in git). If Vault should own them long-term, migrate them to `VaultStaticSecret` after the cluster is fully healthy — but keep them Vault-independent if you want restores to work while Vault is sealed.
