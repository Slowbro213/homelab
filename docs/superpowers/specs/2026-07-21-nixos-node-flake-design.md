# NixOS Node Flake — Design

Date: 2026-07-21

## Goal

Design a NixOS flake that declaratively manages the bare-metal nodes of the "gentoo" k3s
homelab cluster (currently 2 nodes, scaling toward 6). The flake must let the user:

1. **Remotely install** NixOS onto a node from their NixOS workstation
   (`nixos-anywhere` + `disko`), and
2. **Remotely deploy** config changes with
   `nixos-rebuild switch --flake .#<host> --target-host deploy@<ip> --use-remote-sudo`.

The node OS is tuned as a performant, hardened k3s host. This is the concrete realization of
**Phase 3 ("Wipe → install NixOS with k3s running")** of the migration plan in
`2026-07-21-nixos-migration-backup-restore-design.md`, which treated the OS install as an
opaque step. Backup/restore of cluster *data* is out of scope here — it is covered by that
other spec (Velero + Longhorn CSI, Vault raft snapshot).

## Non-goals

- Backup/restore of Longhorn PVCs, Vault, Postgres, etc. — see the migration backup/restore
  spec. This flake only produces "k3s running on NixOS"; Argo CD + Velero repopulate state.
- Changing the in-cluster GitOps layout (`apps/`, `clusters/`), Argo CD app-of-apps ordering,
  or security-baseline policies.
- High availability for the control plane. The cluster stays single-server on sqlite (as
  today). The layout leaves room for HA later but does not implement it.
- Defining the 4 future nodes' concrete hardware. The flake provides a reusable node template
  (`mkNode`) so nodes 3–6 (expected wired bare-metal/VMs on the same LAN) are cheap to add.

## Investigation — current live state (what the flake must reproduce)

Gathered by SSH into both nodes (2026-07-21).

### Node `cachyos` — control-plane (role `server`)
- **Hardware:** Lenovo IdeaPad 1 15AMN7 laptop, 8 cores (Ryzen), 13 GiB RAM.
- **Network: WiFi-only — there is no ethernet port** (Realtek RTL8822CE, `wlan0`). Currently
  `192.168.1.31/24` via DHCP, gateway `192.168.1.1`.
- **Disk:** single 238 GB NVMe (Samsung). Today btrfs `@`-subvolumes + 300 MB EFI.
- **k3s:** `v1.36.0+k3s`, `server`. `node-name: cachyos`, `flannel-backend: host-gw`,
  `tls-san: [192.168.1.31, k3s.gentoo.lan]`, `write-kubeconfig-mode: 0644`. Default addons
  **on** (traefik, servicelb/klipper, coredns, metrics-server, local-path).
- **Longhorn:** `/var/lib/longhorn` ≈ 30 GB on the root fs; `iscsid` active (Longhorn attaches
  volumes as iSCSI `sd*` "VIRTUAL-DISK" devices — this is why open-iscsi is mandatory).
- The laptop must **not suspend on lid close** (it is the sole control plane).

### Node `tux` / `registry.gentoo.lan` — worker (role `agent`)
- **Hardware:** 4 cores (i5-6200U class), 7.6 GiB RAM.
- **Network:** WiFi `wlp1s0` → `192.168.1.25/24` DHCP (plus an unused cellular WWAN iface).
- **Disk:** single 238 GB SanDisk M.2 SATA: 1 GB EFI + 4 GB swap + 233 GB ext4 root.
- **k3s:** `v1.35.5+k3s1` (version-drifted from server), `agent`,
  `K3S_URL=https://192.168.1.31:6443`.

### Cluster-wide must-preserve items
- **open-iscsi (`iscsid`) running on both** — hard Longhorn requirement.
- **`/etc/rancher/k3s/registries.yaml`** on both, identical:
  ```yaml
  mirrors:
    registry.gentoo.lan:
      endpoint: ["http://registry.gentoo.lan"]
  configs:
    "registry.gentoo.lan":
      tls:
        ca_file: /etc/rancher/k3s/certs/gentoo-internal-ca.crt
  ```
- **`/etc/rancher/k3s/certs/gentoo-internal-ca.crt`** — the internal CA public cert (578 B PEM,
  captured; public, safe to commit). Needed to pull images from the internal Zot registry.
- **`/etc/hosts` entries** mapping `registry.gentoo.lan` (and the server also had
  `gentoo.lan`, `argocd.gentoo.lan`, `whoami.gentoo.lan`) → `192.168.1.25`. Needed so nodes can
  resolve/pull the internal registry at boot, before in-cluster DNS exists.
- **SSH `authorized_keys` to preserve** (hard user requirement — the machines that can SSH in
  today must stay able to): `vboxuser@virtualbox`, `slowking@registry`, and the workstation
  key(s) `thanas.papa.24@gmail.com`. All captured.
- **Tailscale** running on both (nodes are on the tailnet alongside the Tailscale-Ingress apps).
- Live sysctls already tuned: `vm.overcommit_memory=1`, `vm.max_map_count=1048576`,
  `fs.inotify.max_user_watches=524288`, `fs.file-max=2097152`, `net.ipv4.ip_forward=1`,
  `net.bridge.bridge-nf-call-iptables=1`, `vm.swappiness=100`.
- k3s **server token** captured to a mode-600 file outside the repo (value withheld from logs;
  a fresh token will be generated for the rebuilt cluster).
- **Node-local seccomp profile** `/var/lib/kubelet/seccomp/gitea-runner-buildah.json` on
  `tux` — the gitea buildah runner (`apps/gitea-runners/runner.yaml`) is nodeSelector-pinned
  there and references it via `seccompProfile.type: Localhost`; kubelet loads it from the node
  filesystem, so it must be placed on the node (added post-investigation, user-flagged).
- **Longhorn NFSv4 client**: node preflight requires NFSv4 client kernel support (for RWX
  volumes / NFS backup targets). Not used today (all 14 PVCs are RWO, v2 data engine off,
  backups go to S3/MinIO) but included for completeness so RWX doesn't silently fail later.

### Drift / cruft to NOT reproduce
- **Docker** installed on both but unused by k3s (containerd) — drop it.
- Stale `flannel.1` VXLAN iface on `tux` from a past backend switch while the server runs
  `host-gw` — the fresh installs will be cleanly `host-gw`.
- btrfs-on-laptop vs ext4-on-worker inconsistency — standardize on XFS.

## Decisions (locked with the user)

| Decision | Choice |
| --- | --- |
| Flake location | `nixos/` at repo root, adjacent to `apps/`, `clusters/`, `docs/` |
| Node IP addressing | **Static IP declared in NixOS over WiFi** (WiFi is forced on the laptop) |
| Root filesystem | **XFS** (best for overlayfs/Longhorn churn; reflink; no fragmentation issues) |
| Future nodes 3–6 | Mostly wired bare-metal/VMs on the same LAN → keep `host-gw`, provide `mkNode` template |
| Flannel backend | **`host-gw`** retained (same-L2, no encapsulation overhead; no `8472/udp`) |
| Deploy access | **Dedicated `deploy` user**, workstation-only key, `NOPASSWD` sudo, used only for `nixos-rebuild --use-remote-sudo`; `slowking` keeps existing keys + password sudo |
| Kernel | Pinned **LTS 6.12** (`linuxPackages_6_12`), overridable per node |
| Auto-updates | **Disabled** — deliberate deploys only |
| Secrets | **sops-nix** (age); host SSH keys stored in sops for stable identity |

## Design

### Directory layout

```
nixos/
├── flake.nix                 # inputs + nixosConfigurations via a mkNode helper
├── flake.lock
├── .sops.yaml                # age recipients (workstation + per-host)
├── README.md                 # install + deploy runbook (exact commands per host)
├── secrets/
│   ├── cluster.yaml          # sops: k3s token, WiFi PSK  (shared)
│   └── hosts/<host>.yaml     # sops: per-host ssh host key (stable identity)
├── modules/                  # shared, composable — the "cluster-wide tuning"
│   ├── common.nix            # users (slowking + deploy), nix.settings, tz, base pkgs, sudo
│   ├── performance.nix       # kernel, zram/zstd, THP=madvise, PSI, sysctls
│   ├── security.nix          # sshd hardening, firewall base, fail2ban, apparmor
│   ├── networking.nix        # WiFi (wpa_supplicant ← sops PSK), extraHosts, static-IP helper
│   ├── k3s-common.nix        # iscsid, registries.yaml, internal-CA cert, longhorn prereqs
│   ├── k3s-server.nix        # role=server + server firewall ports
│   └── k3s-agent.nix         # role=agent  + agent firewall ports
└── hosts/
    ├── cachyos/{default,hardware,disko}.nix   # server, .31, node-name cachyos, wlan0
    └── tux/{default,hardware,disko}.nix       # agent, .25, → https://192.168.1.31:6443, wlp1s0
```

A `mkNode` helper in `flake.nix` reduces a new node to hostname + role + IP + disk device +
WiFi iface (~15 lines). Everything cluster-identical lives in `modules/`; only hardware, IP,
role, and node-name live in `hosts/<n>/`.

### Flake inputs
- `nixpkgs` (release channel, e.g. `nixos-25.05` or `nixos-unstable` — pin at implementation).
- `disko` — declarative partitioning.
- `nixos-anywhere` (via `nix run`, not necessarily a flake input) — remote install.
- `sops-nix` — secret decryption at activation.

### `modules/performance.nix`
- `boot.kernelPackages = pkgs.linuxPackages_6_12` (per-node overridable to `_latest`).
- `boot.kernelParams = [ "transparent_hugepage=madvise" "psi=1" ]`.
- cgroup v2 unified (NixOS/systemd default).
- `zramSwap = { enable = true; algorithm = "zstd"; memoryPercent = 50; }`.
- `boot.kernel.sysctl` reproducing the live-tuned values plus container best-practice:
  `vm.swappiness=100`, `vm.overcommit_memory=1`, `vm.max_map_count=1048576`,
  `fs.inotify.max_user_instances=8192`, `fs.inotify.max_user_watches=524288`,
  `fs.file-max=2097152`, `net.ipv4.ip_forward=1`, `net.bridge.bridge-nf-call-iptables=1`,
  `net.core.somaxconn=4096`, `net.netfilter.nf_conntrack_max` raised.

### `modules/common.nix`
- `users.users.slowking`: normal user, uid 1000, the captured `authorized_keys`, `wheel` group,
  password sudo (interactive). (On old `tux`, slowking was uid 1001 behind Gentoo's `larry`;
  normalize to 1000 — `larry` is a Gentoo default and disappears with the wipe.)
- `users.users.deploy`: workstation-only deploy key, `wheel`, `NOPASSWD` sudo (see security).
- `nix.settings.experimental-features = [ "nix-command" "flakes" ]`, `nix.gc` weekly,
  `nix.settings.auto-optimise-store = true`.
- `time.timeZone`, base packages (`git`, `htop`, `iproute2`, `iptables`, ...). No Docker.

### `modules/k3s-common.nix` (+ role modules)
- `services.k3s` NixOS module (manages containerd + binary). Docker dropped.
- `services.openiscsi.enable = true` with a stable initiator name (Longhorn hard-req).
- `environment.etc."rancher/k3s/registries.yaml"` and
  `environment.etc."rancher/k3s/certs/gentoo-internal-ca.crt"` (public CA) from the repo.
- `networking.extraHosts` → `registry.gentoo.lan` / `*.gentoo.lan` = `192.168.1.25`.
- Longhorn deps: `nfs-utils`, kernel modules `iscsi_tcp`, `br_netfilter`, `overlay`.
- **`k3s-server`:** `services.k3s.role = "server"`, `tokenFile = <sops>`,
  `extraFlags = [ "--flannel-backend=host-gw" "--node-name=cachyos"
  "--tls-san=192.168.1.31" "--tls-san=k3s.gentoo.lan" "--write-kubeconfig-mode=0644" ]`.
  Default addons kept on (matches live).
- **`k3s-agent`:** `role = "agent"`, `serverAddr = "https://192.168.1.31:6443"`,
  `tokenFile = <sops>`.
- Fresh cluster token generated into sops (the captured old token is a fallback only; a wiped
  cluster generates a new CA regardless).

### `modules/networking.nix`
- **Static WiFi** via `wpa_supplicant` (declarative, headless-friendly; not NetworkManager).
  PSK injected from sops via `environmentFile` — never in the Nix store.
- `networking.interfaces.<wifi>.ipv4.addresses` = fixed `.31` / `.25`,
  `networking.defaultGateway = 192.168.1.1`, `networking.nameservers = [ 192.168.1.1 ]`.
- WiFi iface name is per-node (`wlan0` on cachyos, `wlp1s0` on tux) — set in `hosts/<n>/`.
- Laptop: `services.logind.lidSwitch = "ignore"` on `cachyos` (sole control plane).

### `modules/security.nix`
- **sshd:** `PasswordAuthentication = no`, `KbdInteractiveAuthentication = no`,
  `PermitRootLogin = no`. `slowking` keeps the captured keys + password sudo. `deploy` user
  has a workstation-only key and `security.sudo.extraRules` granting it `NOPASSWD` (only path
  used by `nixos-rebuild --use-remote-sudo`).
- **`networking.firewall` per role:**
  - server: `6443/tcp` (API), `10250/tcp` (kubelet), `80,443/tcp` (svclb/traefik ingress).
  - agent: `10250/tcp`, `80,443/tcp`.
  - both: `trustedInterfaces = [ "cni0" "tailscale0" ]`; accept from pod/service CIDRs
    `10.42.0.0/16` + `10.43.0.0/16`; `checkReversePath = "loose"` (WiFi + Tailscale).
- `services.fail2ban.enable` (sshd jail). `security.apparmor.enable = true` (the
  NixOS-supported LSM; SELinux is not the NixOS default path — noted).
- `services.tailscale.enable = true` on both.
- **LAN-only exposure assumed and stated.** If a node becomes internet-facing: restrict the
  `6443`/`10250`/`80`/`443` rules to LAN/tailnet source CIDRs and revisit the deploy path and
  `PermitRootLogin`.
- **`system.autoUpgrade` disabled** — unattended rebuild/reboot would disrupt k3s; updates land
  intentionally via `nixos-rebuild` after `nix flake update` on the workstation.

### Secrets — sops-nix
- `.sops.yaml` recipients: the workstation age key + each host's age key derived from its
  ed25519 SSH host key.
- **Host SSH keys stored in sops** → stable host identity across reinstalls (workstation
  `known_hosts` stays valid; age recipients are known before first boot, resolving the
  bootstrap chicken-and-egg).
- Sealed material: `k3s token`, `WiFi PSK`, per-host `ssh_host_ed25519_key`. The current WiFi
  SSID/PSK will be extracted from the running nodes (root-readable) and sealed; age/host keys
  generated during implementation.

### Disko (`hosts/<n>/disko.nix`)
Single-disk GPT per node: `512 MB EFI (vfat) → remainder XFS root`. No separate
`/var/lib/longhorn` partition — it stays on the root fs (matches today). XFS chosen for
overlayfs/Longhorn small-file churn, reflink support, and freedom from ext4-style
fragmentation under container image layering.

## Workflow (documented in `nixos/README.md`)

### Remote install (per host)
```
nix run github:nix-community/nixos-anywhere -- \
  --flake .#<host> --target-host root@<ip>
```
⚠️ **WiFi-only install is the one sharp edge.** `nixos-anywhere`'s kexec installer can drop the
WiFi link mid-install (its default installer has no WiFi driver/firmware or WPA creds baked
in). **Decision: user is fine installing over WiFi** — no ethernet dongle requirement. This
means the install needs a custom per-host kexec installer image (via `nixos-anywhere --kexec`)
built from the `nixos-images` kexec-installer module plus the node's WiFi
driver/firmware/credentials; see `nixos/README.md` for the mechanism and status (not yet
implemented — flagged as a TODO before the first real install).

### Remote deploy (per host)
```
nixos-rebuild switch --flake .#<host> \
  --target-host deploy@<ip> --use-remote-sudo
```
Builds on the workstation and pushes closures (correct — `tux` is too weak to build locally).
Confirmed compatible with this flake layout and the `deploy` NOPASSWD-sudo model.

## Integration with the migration plan
After both nodes are installed and k3s is up, Phase 4 of
`2026-07-21-nixos-migration-backup-restore-design.md` proceeds unchanged: bootstrap Argo CD →
let infra sync in sync-wave order → re-add Velero → `velero restore` PVCs → unseal Vault.

## Risks / callouts
1. **WiFi-only install** — user approved installing over WiFi (no ethernet dongle); needs a
   custom kexec installer image with WiFi baked in. Most fiddly step.
2. **Single control-plane on sqlite, over WiFi** — no HA, unchanged from today. Future HA means
   `--cluster-init` + embedded etcd + additional server nodes, which adds firewall
   `2379-2380/tcp` and changes the token/join model. `mkNode` leaves room; out of scope now.
3. **Static WiFi IP + host-gw** works because both nodes share one L2 subnet. If future nodes
   land on a different subnet/link, flannel must move to `vxlan` (`8472/udp`) — flagged in the
   "future nodes" decision.

## Open items for the implementation plan
- Pin exact versions: `nixpkgs` channel, `disko`, `sops-nix`, `nixos-anywhere`, and the k3s
  version exposed by the chosen nixpkgs (align server/agent to remove the current drift).
- Generate the workstation age key + per-host host keys; author `.sops.yaml`; extract and seal
  the WiFi SSID/PSK and a fresh k3s token.
- Produce per-node `hardware.nix` (via `nixos-generate-config` during the `nixos-anywhere` run)
  and confirm the WiFi iface names post-install.
- WiFi install mechanism is decided (over WiFi, no dongle); build the per-host custom kexec
  installer image and write the exact commands into `nixos/README.md`.
