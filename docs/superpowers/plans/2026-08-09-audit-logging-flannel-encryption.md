# Kube-apiserver Audit Logging + Alerting, and Flannel Encryption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship kube-apiserver audit logs into the existing Loki/Alloy stack with two Discord alert rules, and encrypt inter-node pod traffic by switching flannel to `wireguard-native`.

**Architecture:** Two NixOS-side changes (audit logging enablement, flannel backend) deployed via `nixos-rebuild switch` — this repo's `nixos/` tree is outside Argo CD's watched path, so it is never deployed by a git push. Two Kubernetes-manifest changes (Alloy scrape config, Loki ruler + alert rules) deployed the normal way for this repo: committing and pushing to `main` auto-applies via Argo CD.

**Tech Stack:** NixOS (flake-based, sops-nix for secrets), k3s v1.34, Grafana Alloy (log shipper, River config), Grafana Loki 6.55.0 chart (SingleBinary deployment mode, S3/MinIO-backed, local sidecar-based ruler), Argo CD (GitOps), kube-prometheus-stack Alertmanager (existing Discord webhook route on `severity: critical`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-09-audit-logging-flannel-encryption-design.md` — audit policy is `Metadata` level only; alert rules are exactly "failed/forbidden spike" and "exec/attach/portforward"; flannel backend is `wireguard-native` (not IPsec); agents do not need a `--flannel-backend` flag.
- `nixos/` changes are deployed with:
  ```
  cd nixos
  NIX_SSHOPTS="-i ~/.ssh/gentoo_deploy_ed25519 -o StrictHostKeyChecking=no" \
    nixos-rebuild switch --flake .#<host> --target-host deploy@<ip> --use-remote-sudo
  ```
  cachyos = `192.168.1.31`, tux = `192.168.1.25`. Always `nix build .#nixosConfigurations.<host>.config.system.build.toplevel --no-link` first to catch eval/build errors before touching the live host.
- Kubernetes-manifest changes under `clusters/gentoo/` and `apps/` auto-deploy the moment they're pushed to `main` (Argo CD `syncPolicy.automated` everywhere) — treat every push as a production deploy.
- This workstation has `kubectl`/`helm` but no `kustomize` and no PyYAML. Validate Helm-sourced Applications with `helm template ... -f <tmpfile-of-valuesObject>`; validate plain-manifest/kustomize directories by eyeballing the YAML (no local kustomize build available) and letting Argo's server-side apply be the real check.
- Do not add a `Co-Authored-By` trailer to any commit in this repo.

---

### Task 1: Kube-apiserver audit logging (NixOS, control-plane only)

**Files:**
- Create: `nixos/assets/audit-policy.yaml`
- Modify: `nixos/modules/k3s-server.nix`

**Interfaces:**
- Produces: audit log at `/var/log/kubernetes/audit/audit.log` on `cachyos` — Task 2 (Alloy) mounts and tails this exact path.

- [ ] **Step 1: Create the audit policy file**

Create `nixos/assets/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
```

- [ ] **Step 2: Wire the policy file and audit flags into k3s-server.nix**

Modify `nixos/modules/k3s-server.nix`. Current content:

```nix
{ config, ... }:
let
  node = config.homelab.node;
in
{
  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.sops.secrets."k3s/token".path;
    extraFlags = [
      "--flannel-backend=host-gw"
      "--node-name=cachyos"
      "--node-ip=${node.ipv4}"
      "--flannel-iface=${node.wifiInterface}"  # pin flannel to WiFi (not tailscale0/wwan)
      "--tls-san=192.168.1.31"
      "--tls-san=k3s.gentoo.lan"
      "--write-kubeconfig-mode=0644"
      # Longhorn only auto-creates its default disk on nodes carrying this label
      # (create-default-disk-labeled-nodes=true). Without it the node reports 0
      # storage and no PVC can schedule.
      "--node-label=node.longhorn.io/create-default-disk=true"
      "--secrets-encryption"
    ];
  };

  # API server, kubelet metrics, servicelb/traefik ingress (live on both nodes today),
  # and node-exporter (hostNetwork, scraped cross-node by Prometheus).
  networking.firewall.allowedTCPPorts = [ 6443 10250 80 443 9100 ];
}
```

Replace it with:

```nix
{ config, ... }:
let
  node = config.homelab.node;
in
{
  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.sops.secrets."k3s/token".path;
    extraFlags = [
      "--flannel-backend=host-gw"
      "--node-name=cachyos"
      "--node-ip=${node.ipv4}"
      "--flannel-iface=${node.wifiInterface}"  # pin flannel to WiFi (not tailscale0/wwan)
      "--tls-san=192.168.1.31"
      "--tls-san=k3s.gentoo.lan"
      "--write-kubeconfig-mode=0644"
      # Longhorn only auto-creates its default disk on nodes carrying this label
      # (create-default-disk-labeled-nodes=true). Without it the node reports 0
      # storage and no PVC can schedule.
      "--node-label=node.longhorn.io/create-default-disk=true"
      "--secrets-encryption"
      "--kube-apiserver-arg=audit-log-path=/var/log/kubernetes/audit/audit.log"
      "--kube-apiserver-arg=audit-policy-file=/etc/rancher/k3s/audit-policy.yaml"
      "--kube-apiserver-arg=audit-log-maxage=7"
      "--kube-apiserver-arg=audit-log-maxbackup=5"
      "--kube-apiserver-arg=audit-log-maxsize=100"
    ];
  };

  # kube-apiserver creates the audit log file itself but not the parent directory.
  systemd.tmpfiles.rules = [
    "d /var/log/kubernetes/audit 0750 root root - -"
  ];

  environment.etc."rancher/k3s/audit-policy.yaml".source = ../assets/audit-policy.yaml;

  # API server, kubelet metrics, servicelb/traefik ingress (live on both nodes today),
  # and node-exporter (hostNetwork, scraped cross-node by Prometheus).
  networking.firewall.allowedTCPPorts = [ 6443 10250 80 443 9100 ];
}
```

- [ ] **Step 3: Build to catch eval errors before touching the live node**

Run: `cd /home/slowking/Github/homelab/nixos && nix build .#nixosConfigurations.cachyos.config.system.build.toplevel --no-link`
Expected: exits 0, no output (or a store path if `--no-link` is dropped). Any Nix eval/type error must be fixed before continuing.

- [ ] **Step 4: Deploy to cachyos**

Run:
```
cd /home/slowking/Github/homelab/nixos
NIX_SSHOPTS="-i ~/.ssh/gentoo_deploy_ed25519 -o StrictHostKeyChecking=no" \
  nixos-rebuild switch --flake .#cachyos --target-host deploy@192.168.1.31 --use-remote-sudo
```
Expected: completes without error; ends with the new generation activated.

- [ ] **Step 5: Verify the audit log is being written**

Run: `ssh slowking@192.168.1.31 "sudo test -f /var/log/kubernetes/audit/audit.log && echo FOUND; sudo tail -3 /var/log/kubernetes/audit/audit.log"`
Expected: `FOUND`, followed by 3 JSON lines each containing `"kind":"Event"` and `"level":"Metadata"`.

- [ ] **Step 6: Commit**

```bash
cd /home/slowking/Github/homelab
git add nixos/assets/audit-policy.yaml nixos/modules/k3s-server.nix
git commit -m "nixos: enable kube-apiserver audit logging (Metadata level)"
```

---

### Task 2: Ship the audit log into Loki via Alloy

**Files:**
- Modify: `clusters/gentoo/apps/infra/logging/alloy-logs.yaml`

**Interfaces:**
- Consumes: audit log path `/var/log/kubernetes/audit/audit.log` (produced by Task 1).
- Produces: Loki log stream labeled `job="kube-audit"` — Task 3's alert rules query `{job="kube-audit"}`.

- [ ] **Step 1: Add the hostPath volume/mount and a file-tailing component**

Modify `clusters/gentoo/apps/infra/logging/alloy-logs.yaml`. In the `spec.source.helm.valuesObject.alloy.configMap.content` block, insert a new pair of River components right before the existing `loki.write "default"` block (i.e. after the `loki.process "pod_logs"` block, so the new block reads from the file and forwards straight to the same writer):

```
              local.file_match "kube_audit" {
                path_targets = [
                  {"__path__" = "/var/log/kubernetes/audit/audit.log", "job" = "kube-audit"},
                ]
              }

              loki.source.file "kube_audit" {
                targets    = local.file_match.kube_audit.targets
                forward_to = [loki.write.default.receiver]
              }

```

The full `content` block becomes:

```
              logging {
                level  = "info"
                format = "logfmt"
              }

              discovery.kubernetes "pods" {
                role = "pod"
              }

              discovery.relabel "pod_logs" {
                targets = discovery.kubernetes.pods.targets

                rule {
                  source_labels = ["__meta_kubernetes_namespace"]
                  target_label  = "namespace"
                }

                rule {
                  source_labels = ["__meta_kubernetes_pod_name"]
                  target_label  = "pod"
                }

                rule {
                  source_labels = ["__meta_kubernetes_pod_container_name"]
                  target_label  = "container"
                }

                rule {
                  source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
                  target_label  = "app"
                }

                rule {
                  source_labels = ["__meta_kubernetes_node_name"]
                  target_label  = "node"
                }
              }

              loki.source.kubernetes "pod_logs" {
                targets    = discovery.relabel.pod_logs.output
                forward_to = [loki.process.pod_logs.receiver]
              }

              loki.process "pod_logs" {
                stage.cri {}

                forward_to = [loki.write.default.receiver]
              }

              local.file_match "kube_audit" {
                path_targets = [
                  {"__path__" = "/var/log/kubernetes/audit/audit.log", "job" = "kube-audit"},
                ]
              }

              loki.source.file "kube_audit" {
                targets    = local.file_match.kube_audit.targets
                forward_to = [loki.write.default.receiver]
              }

              loki.write "default" {
                endpoint {
                  url = "http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push"
                  basic_auth {
                    username = sys.env("LOKI_BASIC_AUTH_USERNAME")
                    password = sys.env("LOKI_BASIC_AUTH_PASSWORD")
                  }
                }
              }
```

- [ ] **Step 2: Add the hostPath volume and mount so Alloy can read the file**

In the same file, still under `spec.source.helm.valuesObject`, add a `controller.volumes.extra` entry and an `alloy.mounts.extra` entry. The `alloy:` block's `securityContext` section and the top-level `controller:` block both already exist — add to them rather than duplicating the keys. Full updated `valuesObject`:

```yaml
      valuesObject:
        global:
          podSecurityContext:
            seccompProfile:
              type: RuntimeDefault

        controller:
          type: daemonset
          volumes:
            extra:
              - name: kube-audit-log
                hostPath:
                  path: /var/log/kubernetes/audit
                  type: DirectoryOrCreate

        alloy:
          extraEnv:
            - name: LOKI_BASIC_AUTH_USERNAME
              valueFrom:
                secretKeyRef:
                  name: loki-basic-auth
                  key: username
            - name: LOKI_BASIC_AUTH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: loki-basic-auth
                  key: password

          mounts:
            extra:
              - name: kube-audit-log
                mountPath: /var/log/kubernetes/audit
                readOnly: true

          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            runAsNonRoot: true
            runAsUser: 473
            runAsGroup: 473
            seccompProfile:
              type: RuntimeDefault
```

(`type: DirectoryOrCreate` means the Alloy pod on `tux`, which has no `/var/log/kubernetes/audit` directory, gets kubelet to create an empty one rather than failing to mount — `local.file_match` there just finds 0 files.)

Note: the `configMap.content` block (Step 1) stays where it is inside `alloy:` — only `mounts.extra` and `securityContext` are shown above for brevity in the diff; do not remove `configMap.create`/`configMap.content` when editing.

- [ ] **Step 3: Validate the rendered Helm output**

```bash
cat > /tmp/alloy-logs-values.yaml <<'EOF'
global:
  podSecurityContext:
    seccompProfile:
      type: RuntimeDefault
controller:
  type: daemonset
  volumes:
    extra:
      - name: kube-audit-log
        hostPath:
          path: /var/log/kubernetes/audit
          type: DirectoryOrCreate
alloy:
  extraEnv:
    - name: LOKI_BASIC_AUTH_USERNAME
      valueFrom:
        secretKeyRef:
          name: loki-basic-auth
          key: username
    - name: LOKI_BASIC_AUTH_PASSWORD
      valueFrom:
        secretKeyRef:
          name: loki-basic-auth
          key: password
  mounts:
    extra:
      - name: kube-audit-log
        mountPath: /var/log/kubernetes/audit
        readOnly: true
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    runAsNonRoot: true
    runAsUser: 473
    runAsGroup: 473
    seccompProfile:
      type: RuntimeDefault
  configMap:
    create: true
    content: |
      logging { level = "info" format = "logfmt" }
rbac:
  create: true
EOF
helm template alloy-logs grafana/alloy --repo https://grafana.github.io/helm-charts --version 1.8.0 -f /tmp/alloy-logs-values.yaml | grep -A3 "kube-audit-log"
```
Expected: shows the `kube-audit-log` volume (hostPath) and volumeMount (mountPath `/var/log/kubernetes/audit`) in the rendered DaemonSet — confirms the schema keys are correct before pushing the full River config change live. (The `configMap.content` here is trimmed to a syntactically-valid stub purely so `helm template` doesn't choke on unrelated content — the real full content from Step 1 goes into the actual committed file, not this validation values file.)

- [ ] **Step 4: Commit and push (this auto-deploys via Argo CD)**

```bash
cd /home/slowking/Github/homelab
git add clusters/gentoo/apps/infra/logging/alloy-logs.yaml
git commit -m "logging: ship kube-apiserver audit log into Loki via Alloy"
git push
```

- [ ] **Step 5: Verify logs are flowing**

```bash
ssh slowking@192.168.1.31 "kubectl get pods -n logging -l app.kubernetes.io/name=alloy -o wide"
```
Expected: an `alloy-logs` pod `Running` on `cachyos` (and one on `registry.gentoo.lan`, harmlessly idle for this stream).

```bash
ssh slowking@192.168.1.31 "kubectl exec -n logging deploy/loki -- true" 2>/dev/null; \
  ssh slowking@192.168.1.31 "kubectl get secret loki-basic-auth -n logging -o jsonpath='{.data.username}' | base64 -d; echo; kubectl get secret loki-basic-auth -n logging -o jsonpath='{.data.password}' | base64 -d"
```
Note the username/password, then query Loki directly for the new stream:
```bash
ssh slowking@192.168.1.31 "curl -s -u '<username>:<password>' 'http://loki-gateway.logging.svc.cluster.local/loki/api/v1/query?query={job=\"kube-audit\"}&limit=1' --resolve loki-gateway.logging.svc.cluster.local:80:127.0.0.1 2>&1 || kubectl run loki-check --rm -i --restart=Never --image=curlimages/curl -n logging -- curl -s -u '<username>:<password>' 'http://loki-gateway.logging.svc.cluster.local/loki/api/v1/query?query={job=\"kube-audit\"}&limit=1'"
```
Expected: JSON response with `"status":"success"` and at least one entry under `data.result`. If empty, check `kubectl logs -n logging -l app.kubernetes.io/name=alloy --tail=50` on the `cachyos` pod for scrape errors before moving on.

---

### Task 3: Loki ruler + audit alert rules → Alertmanager → Discord

**Files:**
- Modify: `clusters/gentoo/apps/infra/logging/loki.yaml`
- Create: `apps/logging/config/kustomization.yaml`
- Create: `apps/logging/config/configmap-audit-alert-rules.yaml`
- Create: `clusters/gentoo/apps/infra/logging/logging-config.yaml`

**Interfaces:**
- Consumes: Loki log stream `{job="kube-audit"}` (produced by Task 2), Alertmanager at `http://monitoring-kube-prometheus-alertmanager.monitoring.svc.cluster.local:9093` (existing).
- Produces: two firing alerts labeled `severity: critical`, which the existing `apps/monitoring/config/alertmanagerconfig-discord.yaml` route already matches — no changes needed there.

- [ ] **Step 1: Enable the ruler in the Loki chart values**

Modify `clusters/gentoo/apps/infra/logging/loki.yaml`. Add a `rulerConfig` key inside the existing `loki:` block (as a sibling of `limits_config`), and a new top-level `sidecar:` block (sibling of `loki:`, `singleBinary:`, etc.). Insert `rulerConfig` right after `limits_config`:

```yaml
          limits_config:
            retention_period: 168h

          rulerConfig:
            enable_api: true
            alertmanager_url: http://monitoring-kube-prometheus-alertmanager.monitoring.svc.cluster.local:9093
            ring:
              kvstore:
                store: inmemory
            storage:
              type: local
              local:
                directory: /rules
            wal:
              dir: /var/loki/ruler-wal
```

Add the new top-level block (place it after the existing `lokiCanary:` block, before `backend:`):

```yaml
        sidecar:
          rules:
            folderAnnotation: k8s-sidecar-target-directory
```

- [ ] **Step 2: Create the alert rules ConfigMap**

Create `apps/logging/config/configmap-audit-alert-rules.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-audit-alert-rules
  namespace: logging
  labels:
    loki_rule: "true"
  annotations:
    # Loki's local ruler storage is per-tenant; auth_enabled:false maps every
    # request to tenant "fake", so the sidecar must drop this file under
    # /rules/fake rather than flat under /rules.
    k8s-sidecar-target-directory: /rules/fake
data:
  kube-audit-alerts.yaml: |
    groups:
      - name: kube-audit-alerts
        rules:
          - alert: KubeAuditFailedRequestSpike
            expr: |
              count_over_time({job="kube-audit"} | json | stage="ResponseComplete" | responseStatus_code=~"401|403" [5m]) > 20
            for: 0m
            labels:
              severity: critical
            annotations:
              summary: "Spike in failed/forbidden kube-apiserver requests"
              description: "More than 20 401/403 kube-apiserver responses in the last 5 minutes."
          - alert: KubeAuditExecIntoWorkload
            expr: |
              count_over_time({job="kube-audit"} | json | stage="ResponseComplete" | objectRef_subresource=~"exec|attach|portforward" [1m]) > 0
            for: 0m
            labels:
              severity: critical
            annotations:
              summary: "exec/attach/portforward into a pod"
              description: "{{ $labels.user_username }} performed {{ $labels.objectRef_subresource }} on {{ $labels.objectRef_namespace }}/{{ $labels.objectRef_name }}"
```

- [ ] **Step 3: Wire the ConfigMap into a kustomization**

Create `apps/logging/config/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap-audit-alert-rules.yaml
```

- [ ] **Step 4: Create the Argo Application for the loose logging manifests**

Create `clusters/gentoo/apps/infra/logging/logging-config.yaml` (mirrors the existing `monitoring-config.yaml` pattern exactly):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: logging-config
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://github.com/Slowbro213/homelab.git
    targetRevision: HEAD
    path: apps/logging/config
  destination:
    server: https://kubernetes.default.svc
    namespace: logging
  syncPolicy:
    automated:
      enabled: true
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 5: Validate the Loki values render**

```bash
cat > /tmp/loki-values.yaml <<'EOF'
loki:
  auth_enabled: false
  limits_config:
    retention_period: 168h
  rulerConfig:
    enable_api: true
    alertmanager_url: http://monitoring-kube-prometheus-alertmanager.monitoring.svc.cluster.local:9093
    ring:
      kvstore:
        store: inmemory
    storage:
      type: local
      local:
        directory: /rules
    wal:
      dir: /var/loki/ruler-wal
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  storage:
    type: s3
    bucketNames:
      chunks: loki
      ruler: loki
      admin: loki
    s3:
      endpoint: minio.minio.svc.cluster.local:9000
      region: us-east-1
      s3ForcePathStyle: true
      insecure: true
deploymentMode: SingleBinary
singleBinary:
  replicas: 1
sidecar:
  rules:
    folderAnnotation: k8s-sidecar-target-directory
EOF
helm template loki grafana/loki --repo https://grafana.github.io/helm-charts --version 6.55.0 -f /tmp/loki-values.yaml | grep -A15 "ruler_config"
```
Expected: rendered config shows `alertmanager_url`, `storage: {type: local, local: {directory: /rules}}` under `ruler_config`.

- [ ] **Step 6: Commit and push (auto-deploys via Argo CD)**

```bash
cd /home/slowking/Github/homelab
git add clusters/gentoo/apps/infra/logging/loki.yaml clusters/gentoo/apps/infra/logging/logging-config.yaml apps/logging/config/kustomization.yaml apps/logging/config/configmap-audit-alert-rules.yaml
git commit -m "logging: enable Loki ruler and add audit-log alert rules"
git push
```

- [ ] **Step 7: Verify the rule group loaded**

```bash
ssh slowking@192.168.1.31 "kubectl get application logging-config -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}{\"\\n\"}'"
ssh slowking@192.168.1.31 "kubectl get pods -n logging -l app.kubernetes.io/name=loki"
```
Expected: `logging-config` app `Synced`/`Healthy`; loki pod shows 2 containers ready (`loki` + `loki-sc-rules` sidecar), no restarts.

Query Loki's ruler API directly for the loaded group (use the `loki-basic-auth` credentials fetched in Task 2 Step 5):
```bash
ssh slowking@192.168.1.31 "kubectl run loki-rules-check --rm -i --restart=Never --image=curlimages/curl -n logging -- curl -s -u '<username>:<password>' http://loki-gateway.logging.svc.cluster.local/loki/api/v1/rules"
```
Expected: response body contains `kube-audit-alerts` with both `KubeAuditFailedRequestSpike` and `KubeAuditExecIntoWorkload`. If the group is missing, check `kubectl logs -n logging -l app.kubernetes.io/name=loki -c loki-sc-rules` for the sidecar's view of what it wrote and where, and `kubectl logs -n logging -l app.kubernetes.io/name=loki -c loki` for ruler-side load errors — the most likely failure mode is the tenant subdirectory (`/rules/fake`) not matching what `rulerConfig.storage.local.directory` expects; adjust `k8s-sidecar-target-directory` accordingly.

- [ ] **Step 8: Sanity-trigger the exec/attach alert**

```bash
ssh slowking@192.168.1.31 "kubectl exec -n logging deploy/loki -- true"
```
Wait about a minute for the audit event to land in Loki and the ruler to evaluate, then check Alertmanager:
```bash
ssh slowking@192.168.1.31 "kubectl exec -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager -- wget -qO- http://localhost:9093/api/v2/alerts 2>&1 | grep -o 'KubeAuditExecIntoWorkload'"
```
Expected: `KubeAuditExecIntoWorkload` appears — and a corresponding message should land in Discord within `groupWait` (30s) of the alert firing. This is the real end-to-end proof the whole pipeline works.

---

### Task 4: Encrypt inter-node traffic (flannel wireguard-native)

**Files:**
- Modify: `nixos/modules/k3s-common.nix`
- Modify: `nixos/modules/k3s-server.nix`
- Modify: `nixos/modules/k3s-agent.nix`

**Interfaces:** none (leaf task, no downstream consumers in this plan).

- [ ] **Step 1: Load the wireguard kernel module on both nodes**

Modify `nixos/modules/k3s-common.nix`. Change:

```nix
  boot.kernelModules = [ "iscsi_tcp" "br_netfilter" "overlay" "dm_crypt" ];
```
to:
```nix
  boot.kernelModules = [ "iscsi_tcp" "br_netfilter" "overlay" "dm_crypt" "wireguard" ];
```

- [ ] **Step 2: Switch the flannel backend and open the WireGuard port on the server**

Modify `nixos/modules/k3s-server.nix`. Change:
```nix
      "--flannel-backend=host-gw"
```
to:
```nix
      "--flannel-backend=wireguard-native"
```

Change:
```nix
  networking.firewall.allowedTCPPorts = [ 6443 10250 80 443 9100 ];
```
to:
```nix
  networking.firewall.allowedTCPPorts = [ 6443 10250 80 443 9100 ];
  networking.firewall.allowedUDPPorts = [ 51820 ];
```

- [ ] **Step 3: Open the WireGuard port on the agent**

Modify `nixos/modules/k3s-agent.nix`. Change:
```nix
  networking.firewall.allowedTCPPorts = [ 10250 80 443 9100 ];
```
to:
```nix
  networking.firewall.allowedTCPPorts = [ 10250 80 443 9100 ];
  networking.firewall.allowedUDPPorts = [ 51820 ];
```

- [ ] **Step 4: Build both node configs to catch eval errors first**

```bash
cd /home/slowking/Github/homelab/nixos
nix build .#nixosConfigurations.cachyos.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.tux.config.system.build.toplevel --no-link
```
Expected: both exit 0.

- [ ] **Step 5: Deploy to both nodes**

Deploy the server first (it defines the backend), then the agent immediately after — the cluster will run briefly mixed (server on wireguard-native, agent still on the old flannel state) until the agent's rebuild completes, which is expected and self-resolves within the ~1 minute gap between these two commands:

```bash
cd /home/slowking/Github/homelab/nixos
NIX_SSHOPTS="-i ~/.ssh/gentoo_deploy_ed25519 -o StrictHostKeyChecking=no" \
  nixos-rebuild switch --flake .#cachyos --target-host deploy@192.168.1.31 --use-remote-sudo
NIX_SSHOPTS="-i ~/.ssh/gentoo_deploy_ed25519 -o StrictHostKeyChecking=no" \
  nixos-rebuild switch --flake .#tux --target-host deploy@192.168.1.25 --use-remote-sudo
```

- [ ] **Step 6: Verify the WireGuard tunnel is up**

```bash
ssh slowking@192.168.1.31 "sudo wg show"
ssh slowking@192.168.1.25 "sudo wg show"
```
Expected: each shows one peer with a non-empty `latest handshake` (within the last couple of minutes).

- [ ] **Step 7: Verify cross-node pod connectivity survived**

```bash
ssh slowking@192.168.1.31 "kubectl get nodes -o wide"
ssh slowking@192.168.1.31 "kubectl get pods -A --no-headers | grep -vE '([0-9]+)/\1 +Running|Completed'"
```
Expected: both nodes `Ready`; no new crash-looping/pending pods beyond whatever pre-existing state was already known-bad before this task.

```bash
ssh slowking@192.168.1.31 "curl -s http://192.168.1.31:9090/api/v1/query?query=up{job=\"node-exporter\"} | grep -o '\"node\":\"[^\"]*\"'"
```
Expected: both `cachyos` and `registry.gentoo.lan` appear — Prometheus (on one node) is successfully scraping node-exporter on both nodes over the pod network, proving cross-node traffic works end-to-end through the new encrypted tunnel.

- [ ] **Step 8: Commit**

```bash
cd /home/slowking/Github/homelab
git add nixos/modules/k3s-common.nix nixos/modules/k3s-server.nix nixos/modules/k3s-agent.nix
git commit -m "nixos: encrypt inter-node flannel traffic (host-gw -> wireguard-native)"
```

---

## Plan Self-Review Notes

- **Spec coverage:** Section 1 (audit logging) → Task 1 + Task 2. Section 2 (Loki alerting) → Task 3. Section 3 (flannel) → Task 4. All three spec sections have a corresponding task.
- **Known uncertainty, called out inline rather than hidden:** Loki's local ruler storage tenant-subdirectory requirement (Task 3, Step 2/7) is my best-informed design based on the chart's sidecar `folderAnnotation` mechanism, but I have not run this exact chart version live — Step 7 has an explicit, concrete diagnostic path (check `loki-sc-rules` and `loki` container logs) if the rule group doesn't show up, rather than a placeholder "add error handling."
- **Type/name consistency:** `job="kube-audit"` is defined once in Task 2 Step 1 and reused verbatim in Task 3's two LogQL expressions. Audit log path `/var/log/kubernetes/audit/audit.log` is defined once in Task 1 and reused verbatim in Task 2. `k8s-sidecar-target-directory` annotation key is defined in Task 3 Step 1 (`sidecar.rules.folderAnnotation`) and reused verbatim in Step 2 (ConfigMap annotation).
