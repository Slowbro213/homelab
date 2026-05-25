# Gitea Frontend Pipeline

Gitea is the source UI and CI trigger. zot remains the OCI registry for built images at `registry.gentoo.lan`.

## Repository Layout

Each frontend repository should include:

```text
Dockerfile
.gitea/workflows/build.yaml
deploy/k8s/deployment.yaml
deploy/k8s/service.yaml
deploy/k8s/ingress.yaml
deploy/k8s/network-policy.yaml
deploy/k8s/kustomization.yaml
```

Use `templates/gitea-frontend/` in this homelab repo as the starting point.

## Runtime Image

The template uses `nginxinc/nginx-unprivileged:1.29.0-alpine`, listens on 8080, and runs as a non-root user. The Deployment keeps `allowPrivilegeEscalation: false`, drops all capabilities, disables service account token mounting, and sets resource requests/limits.

## Build Workflow

The example workflow builds on pushes to `main`, pushes `registry.gentoo.lan/frontends/<repo>:<commit-sha>`, and optionally copies that immutable image to `:main` for convenience only. Kubernetes manifests should use the commit SHA tag or digest, not `:main`.

The workflow assumes a non-privileged runner design:

- Gitea Actions runner runs in an isolated `gitea-runners` namespace if deployed.
- Builds use rootless BuildKit, not privileged Docker-in-Docker.
- Runner secrets provide `ZOT_USERNAME` and `ZOT_PASSWORD`.
- The runner trusts the internal CA and can reach `gitea-http.gitea.svc.cluster.local:3000` and `registry.gentoo.lan`.

If `act_runner` is later configured to require Docker-compatible container jobs, isolate it in a dedicated namespace and document the elevated security tradeoff before enabling privileged pods.

## Example Argo CD Application

Keep this example outside `clusters/gentoo/apps/` until the frontend repo is real and ready to deploy.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-frontend
  namespace: argocd
spec:
  project: apps
  source:
    repoURL: https://git.thanaspapa.com/thanas/my-frontend.git
    targetRevision: main
    path: deploy/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Runner Secret Template

Do not commit real values. Store these in Vault or as Gitea runner secrets:

```text
ZOT_USERNAME=<zot push user>
ZOT_PASSWORD=<zot push password or token>
```

## Onboarding Checklist

1. Create the repository in Gitea through `https://git.gentoo.lan`.
2. Copy `templates/gitea-frontend/` into the repository.
3. Update names, hosts, NetworkPolicy labels, and resource sizing in `deploy/k8s/`.
4. Push to `main` and confirm the image lands in `registry.gentoo.lan/frontends/<repo>:<sha>`.
5. Wait for zot CVE data to populate in the search extension.
6. Add a real Argo CD Application under `clusters/gentoo/apps/` pointing at the repo and `deploy/k8s`.
7. Pin the Deployment image to the commit SHA tag or digest produced by the build.
