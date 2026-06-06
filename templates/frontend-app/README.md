# Frontend App Template

This template gives you a secure default deployment shape for public frontend apps.

You provide your own `Dockerfile` per repo. A sample is included in `Dockerfile.example`.

## Required Files

- `.gitea/workflows/build-and-scan.yaml`
- `deploy/k8s/namespace.yaml`
- `deploy/k8s/deployment.yaml`
- `deploy/k8s/service.yaml`
- `deploy/k8s/ingress.yaml`
- `deploy/k8s/network-policy.yaml`
- `deploy/k8s/kustomization.yaml`

## Runner Requirements

The runner label used by this template is `gitea-kaniko`.

Runner environment must provide:

- `kaniko-executor`
- `crane`
- `trivy`
- access to `registry.gentoo.lan`
- secrets `ZOT_USERNAME` and `ZOT_PASSWORD`

## Usage

1. Copy this template into your Gitea repository.
2. Replace every `REPLACE_*` value in `deploy/k8s`.
3. Add your project Dockerfile (or adapt `Dockerfile.example`).
4. Add an Argo CD `Application` using `deploy/k8s/argocd-application.example.yaml`.
5. Push to `main` and verify CI built, scanned, and pushed the image.
6. Verify Argo CD Image Updater wrote `deploy/k8s/.argocd-source-<app>.yaml` and Argo CD rolled out the new digest.

## Automatic Deployments

Frontend apps opt in to the shared Image Updater with the label `image-updater.gentoo.lan/enabled: "true"` on their Argo CD `Application`.

Use the example annotations to track `registry.gentoo.lan/frontends/<repo>:main` with the `digest` strategy. Image Updater writes only `deploy/k8s/.argocd-source-<app>.yaml`, and the workflow ignores deployment-only commits to avoid build loops.
