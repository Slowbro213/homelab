# Gentoo Cluster Security Notes

## ArgoCD `infra` Project

The `infra` AppProject is intentionally broad right now:

- `clusterResourceWhitelist` allows every group/kind.
- `namespaceResourceWhitelist` allows every group/kind.
- The project deploys controllers and charts that create CRDs, ClusterRoles, ClusterRoleBindings, admission webhooks, storage classes, network resources, and service workloads.

This is effectively a cluster-admin capability for any Application admitted into the `infra` project. Keep membership limited to trusted GitOps manifests in this repository.

Target follow-up:

1. Render each infra chart at the pinned version.
2. Inventory cluster-scoped resources per Application.
3. Split controller installers from ordinary namespace services where practical.
4. Replace the wildcard whitelists with the observed API groups and kinds.

## Required Vault KV Entries

These GitOps manifests expect the following KV v2 paths under the `secret` mount:

- `secret/loki/basic-auth`
  - `.htpasswd`: htpasswd line used by the Loki nginx gateway.
  - `username`: client username for Alloy and Grafana.
  - `password`: client password for Alloy and Grafana.
- `secret/zot/auth`
  - `.htpasswd`: htpasswd line for Docker-compatible registry login.
  - `username`: operational note only; keep it aligned with the htpasswd user.
  - `password`: operational note only; keep it aligned with the htpasswd user.
- `secret/zot/oidc`
  - `oidc-credentials.json`: JSON object with `clientid` and `clientsecret`.

Zot access policy currently grants admin and push rights to the htpasswd user `registry-admin`, Authentik group `zot-admins`, and Authentik group `zot-pushers`.
The Authentik provider slug is expected to be `zot`, with issuer `https://sso.gentoo.lan/application/o/zot/` and redirect URI `https://registry.gentoo.lan/zot/auth/callback/oidc`.
