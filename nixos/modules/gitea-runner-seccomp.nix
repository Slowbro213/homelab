{ ... }:
{
  # Node-local seccomp profile required by the gitea buildah runner.
  # The runner pod (apps/gitea-runners/runner.yaml) sets
  #   securityContext.seccompProfile.type: Localhost
  #   localhostProfile: gitea-runner-buildah.json
  # and is nodeSelector-pinned to registry.gentoo.lan (this node). kubelet loads
  # the referenced profile from <kubelet-root>/seccomp/ on the node's filesystem,
  # so the file must exist here or buildah (which needs unshare/mount syscalls that
  # RuntimeDefault blocks) cannot start. Import this module on any node the runner
  # may schedule onto.
  systemd.tmpfiles.rules = [
    "d /var/lib/kubelet/seccomp 0755 root root -"
    "L+ /var/lib/kubelet/seccomp/gitea-runner-buildah.json - - - - ${../assets/gitea-runner-buildah.json}"
  ];
}
