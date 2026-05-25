# Gitea Frontend Template

Replace `frontend-template` with the repository name, update the Ingress host, and replace `REPLACE_WITH_COMMIT_SHA` with an immutable image tag built by Gitea Actions.

The workflow expects a runner environment with:

- `buildctl` and `crane` on PATH.
- A rootless BuildKit daemon reachable at `tcp://buildkitd.gitea-runners.svc.cluster.local:1234`.
- `ZOT_USERNAME` and `ZOT_PASSWORD` injected as runner secrets.

Do not deploy `:main` in Kubernetes. Use the commit SHA tag or an image digest.
