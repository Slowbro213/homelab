# gitea-buildah runner image

This is the tools image the `gitea-runner` Deployment (`apps/gitea-runners/runner.yaml`) runs.
It's `gitea/act_runner` plus the CLI tools app CI workflows need to build and publish images:
`buildah` (image builds), `trivy` (vulnerability scanning), `crane` (registry copy/digest
lookups). The act_runner is registered with the label `gitea-buildah`, which is what app
workflows target via `runs-on: gitea-buildah`.

It used to be built around `kaniko-executor` instead of `buildah` — hence the runner label was
`gitea-kaniko`. Kaniko was dropped because in act_runner's host-networking/host-mode execution
it unpacks the target image directly over the pod's own root filesystem, which destroys the
runner's own `git`/`act_runner`/`crane`/`trivy` mid-build. buildah builds into its own isolated
container storage (`/var/lib/containers/storage`, see `storage.conf`) and never touches `/`, so
the runner survives every build. The label was renamed to `gitea-buildah` to match.

## How it's built

There's no CI pipeline for this image (it's infra tooling, not an app) — it's built and pushed
by hand from one of the cluster nodes:

```sh
# on a node with `docker` (e.g. tux/registry.gentoo.lan)
cd apps/gitea-runners/runner-image
docker build -t registry.gentoo.lan/infra/gitea-runner-tools:0.2.11-1 .

# push into the internal Zot registry (uses skopeo since the registry only accepts OCI
# manifests, not docker v2s2 — docker push alone would be rejected with 415)
sudo skopeo copy --format oci \
  --dest-tls-verify=false \
  --dest-creds 'registry-admin:<password>' \
  docker-daemon:registry.gentoo.lan/infra/gitea-runner-tools:0.2.11-1 \
  docker://registry.gentoo.lan/infra/gitea-runner-tools:0.2.11-1
```

Then bump `image:` in `apps/gitea-runners/runner.yaml` (or, if the tag is reused as-is, just
let the running pod get recreated / restart it) and push to `main` as usual so Argo CD reconciles
the Deployment.

## A wrinkle: this Dockerfile is self-referential

`FROM registry.gentoo.lan/infra/gitea-runner-tools:0.2.11-1` in this Dockerfile points at the
*same tag* the build produces — the buildah layer was built on top of the last kaniko-based
image under that tag, then pushed back to overwrite it in place, rather than cutting a new tag.
That means:

- Rebuilding this Dockerfile today pulls an image that **already** has buildah and no kaniko,
  so the `apk add`/`rm -f kaniko-executor` steps become no-ops — harmless, but the Dockerfile is
  no longer reproducible from a clean base purely by reading it.
- The true origin (`gitea/act_runner:0.2.11` + trivy + crane, kaniko-executor originally baked
  in the same way) predates what's tracked in this repo.

If this image needs a real rebuild-from-scratch, start from `gitea/act_runner:<version>` and
layer trivy, crane, and buildah on fresh rather than `FROM`-ing the mutable `0.2.11-1` tag —
and cut a new version tag (e.g. `0.2.12-1`) instead of overwriting `0.2.11-1` again, so the tag
means something stable.

## Files

- `Dockerfile` — the buildah layer added on top of the previous tools image.
- `storage.conf` — buildah/containers storage config: `vfs` driver, so builds need no
  `/dev/fuse` and work as root in an unprivileged (baseline PodSecurity) pod.
- `containers.conf` — `chroot` isolation (avoids needing new namespaces/CAP_SYS_ADMIN) and
  `netns = "host"` (build steps reuse the pod's network instead of setting up rootless
  networking).

See `apps/gitea-runners/runner.yaml` for how these get consumed at runtime: `buildah bud` is
invoked with `--isolation chroot --storage-driver vfs --network host` from app CI workflows
(e.g. `programmingclub`'s `.gitea/workflows/build-and-scan.yaml`), matching this config.
