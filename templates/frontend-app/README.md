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

The runner label used by this template is `gitea-rootless-buildkit`.

Runner environment must provide:

- `buildctl`
- `crane`
- `trivy`
- access to `tcp://buildkitd.gitea-runners.svc.cluster.local:1234`
- access to `registry.gentoo.lan`
- secrets `ZOT_USERNAME` and `ZOT_PASSWORD`

## Usage

1. Copy this template into your Gitea repository.
2. Replace every `REPLACE_*` value.
3. Add your project Dockerfile (or adapt `Dockerfile.example`).
4. Push to `main` and verify CI built, scanned, and pushed the image.
5. Set deployment image to immutable digest from CI output.
