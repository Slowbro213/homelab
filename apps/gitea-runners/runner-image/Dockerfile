# New gitea runner tools image: replaces kaniko (which destroys the runner's own
# rootfs when run in act_runner host mode) with buildah. buildah builds into its
# own isolated container storage and never unpacks the target image over "/",
# so the runner's git/act_runner/crane/trivy survive every build.
#
# Based on the existing image so act_runner, its entrypoint (/opt/act/run.sh),
# crane, trivy and the CA wiring are preserved verbatim.
FROM registry.gentoo.lan/infra/gitea-runner-tools:0.2.11-1

USER root

# buildah + fuse-overlayfs (fuse kept available in case /dev/fuse is wired in later;
# default storage driver below is vfs, which needs no /dev/fuse and no privileges).
RUN apk add --no-cache buildah fuse-overlayfs netavark aardvark-dns

# Drop kaniko so nothing can accidentally invoke the rootfs-destroying builder again.
RUN rm -f /usr/local/bin/kaniko-executor && rm -rf /kaniko

# Container storage / behaviour config. vfs + chroot isolation is the combination
# that works in an unprivileged (baseline PodSecurity) pod running as root: chroot
# isolation avoids needing new namespaces, vfs avoids needing /dev/fuse.
COPY storage.conf /etc/containers/storage.conf
COPY containers.conf /etc/containers/containers.conf

# Registry TLS trust for buildah/skopeo: reuse the gentoo CA already mounted by the
# deployment at /etc/ssl/certs/gentoo-ca.crt (SSL_CERT_FILE points there at runtime).
# buildah/skopeo read the system trust store, so also register it there at build time
# if present; runtime relies on the mounted file + REGISTRY paths below.
RUN mkdir -p /etc/containers/certs.d/registry.gentoo.lan

LABEL org.opencontainers.image.description="gitea act_runner + buildah (kaniko removed)"
