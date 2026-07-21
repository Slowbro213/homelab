# NixOS Node Flake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `nixos/` flake in this repo that declaratively defines the two k3s cluster nodes (`cachyos` server, `tux` agent), installable via `nixos-anywhere` and deployable via `nixos-rebuild --target-host … --use-remote-sudo`, tuned as performant/hardened k3s hosts.

**Architecture:** One flake at `nixos/`, with cluster-wide tuning in composable `modules/` and per-node hardware/role/IP in `hosts/<n>/`. A `mkNode` helper assembles each `nixosConfiguration`. Secrets (k3s token, WiFi PSK, per-host SSH host keys) are sealed with sops-nix (age). Verification is by Nix **evaluation and closure build on the workstation** — the destructive `nixos-anywhere` install itself is NOT run by this plan; it is executed during the migration window (Phase 3 of the backup/restore spec) per the runbook this plan produces.

**Tech Stack:** Nix flakes, NixOS (stable `nixos-25.11`), disko, sops-nix, age, k3s, wpa_supplicant, Tailscale.

## Global Constraints

- Flake lives at `nixos/` (repo root, adjacent to `apps/`, `clusters/`, `docs/`). This repo is git-tracked; **flakes only see git-tracked files — `git add` new files before every `nix eval`/`nix build`**.
- Workstation is NixOS with `nix`, `sops`, `age`, `nixos-rebuild` already present; `ssh-to-age` is obtained on demand via `nix shell nixpkgs#ssh-to-age`.
- Root filesystem: **XFS**. Flannel backend: **host-gw**. Kernel: pinned **LTS `linuxPackages_6_12`**.
- Cluster CIDRs: pods `10.42.0.0/16`, services `10.43.0.0/16`. Gateway/DNS `192.168.1.1`.
- Node identities (fixed): `cachyos` = server, `192.168.1.31`, iface `wlan0`; `tux` = agent, `192.168.1.25`, iface `wlp1s0`, joins `https://192.168.1.31:6443`.
- `services.k3s` `tls-san` = `192.168.1.31` + `k3s.gentoo.lan`; `node-name` for the server is `cachyos`.
- **Admin SSH keys that MUST keep working** on both nodes (hard requirement — union of what both nodes currently authorize):
  - `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFzUvw59McgsCCf+ucUaclE6M9C/UKIQ1YdwF7eoYQs+ vboxuser@virtualbox`
  - `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINirl801uWMh5QFXNwZXZ2phVm21JtrQ5eXnxu8ZQlUo slowking@registry`
  - `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9Mv/9PY7JNEY14lzzbVYxiODeGRCClZQRoNIhxqjTe thanas.papa.24@gmail.com`
  - `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJLAOt1EjmWI+de0iV9dDoc/Avw3kM6bA1uIANluBVbV thanas.papa.24@gmail.com`
- **No secret values in the Nix store or git.** WiFi PSK and k3s token come only from sops. Public keys/certs may be committed.
- Do **not** run `nixos-anywhere`/`nixos-rebuild switch` against the live nodes as part of this plan. Those are gated on the migration backup phase and run manually via `nixos/README.md`.

---

### Task 1: Flake skeleton, inputs, and `mkNode` helper

**Files:**
- Create: `nixos/flake.nix`
- Create: `nixos/.gitignore`

**Interfaces:**
- Produces: `nixosConfigurations.cachyos` and `nixosConfigurations.tux` (referenced by every later task's eval/build commands). `mkNode :: hostName -> nixosSystem` importing `modules/*` + `hosts/<hostName>/{default,hardware,disko}.nix`.

- [ ] **Step 1: Write the flake**

`nixos/flake.nix`:
```nix
{
  description = "gentoo k3s homelab — NixOS node configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, ... }:
    let
      system = "x86_64-linux";
      mkNode = hostName:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit self; };
          modules = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            ./modules/common.nix
            ./modules/performance.nix
            ./modules/security.nix
            ./modules/networking.nix
            ./modules/k3s-common.nix
            ./hosts/${hostName}/default.nix
            ./hosts/${hostName}/hardware.nix
            ./hosts/${hostName}/disko.nix
          ];
        };
    in
    {
      nixosConfigurations = {
        cachyos = mkNode "cachyos";
        tux = mkNode "tux";
      };
    };
}
```

`nixos/.gitignore`:
```
# never commit decrypted secrets or private keys
secrets/**/*.dec
keys/*_ed25519_key
```

- [ ] **Step 2: Verify inputs resolve and lock**

Run:
```bash
cd /home/slowking/Github/homelab/nixos && git -C .. add nixos/flake.nix nixos/.gitignore && nix flake lock
```
Expected: creates `nixos/flake.lock` with `nixpkgs`, `disko`, `sops-nix`; no error. (Eval of `nixosConfigurations` will fail until modules exist — that is expected now.)

- [ ] **Step 3: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/flake.nix nixos/flake.lock nixos/.gitignore
git -C /home/slowking/Github/homelab commit -m "nixos: flake skeleton with disko + sops-nix inputs and mkNode helper"
```

---

### Task 2: `modules/performance.nix` — kernel, zram, THP/PSI, sysctls

**Files:**
- Create: `nixos/modules/performance.nix`

**Interfaces:**
- Produces: sets `boot.kernelPackages`, `boot.kernelParams`, `zramSwap`, `boot.kernel.sysctl`. No symbols other tasks consume by name.

- [ ] **Step 1: Write the module**

`nixos/modules/performance.nix`:
```nix
{ pkgs, lib, ... }:
{
  # Pinned LTS for a predictable cluster substrate; override per-node if needed.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_6_12;

  boot.kernelParams = [
    "transparent_hugepage=madvise"
    "psi=1"
  ];

  # cgroup v2 unified is the systemd/NixOS default — no action needed.

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  boot.kernel.sysctl = {
    "vm.swappiness" = 100;              # zram-appropriate
    "vm.overcommit_memory" = 1;
    "vm.max_map_count" = 1048576;
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 524288;
    "fs.file-max" = 2097152;
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.core.somaxconn" = 4096;
    "net.netfilter.nf_conntrack_max" = 262144;
  };
}
```

- [ ] **Step 2: Commit** (eval happens after the host stubs exist in Task 9)

```bash
git -C /home/slowking/Github/homelab add nixos/modules/performance.nix
git -C /home/slowking/Github/homelab commit -m "nixos: performance module (LTS kernel, zram, THP/PSI, sysctls)"
```

---

### Task 3: `modules/common.nix` — users, deploy access, nix settings

**Files:**
- Create: `nixos/modules/common.nix`
- Create: `nixos/keys/deploy.pub` (generated in Step 2)

**Interfaces:**
- Consumes: nothing.
- Produces: user `slowking` (uid 1000, wheel, password sudo), user `deploy` (wheel, NOPASSWD sudo, key from `./keys/deploy.pub`). Admin keys embedded from Global Constraints.

- [ ] **Step 1: Write the module**

`nixos/modules/common.nix`:
```nix
{ config, pkgs, lib, ... }:
let
  adminKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFzUvw59McgsCCf+ucUaclE6M9C/UKIQ1YdwF7eoYQs+ vboxuser@virtualbox"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINirl801uWMh5QFXNwZXZ2phVm21JtrQ5eXnxu8ZQlUo slowking@registry"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9Mv/9PY7JNEY14lzzbVYxiODeGRCClZQRoNIhxqjTe thanas.papa.24@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJLAOt1EjmWI+de0iV9dDoc/Avw3kM6bA1uIANluBVbV thanas.papa.24@gmail.com"
  ];
in
{
  time.timeZone = "Europe/Athens";
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    trusted-users = [ "root" "deploy" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  users.mutableUsers = false;

  users.users.slowking = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = adminKeys;
    # Interactive password sudo for hands-on admin; hash delivered via sops (Task 8).
    hashedPasswordFile = config.sops.secrets."slowking/hashed-password".path;
  };

  users.users.deploy = {
    isNormalUser = true;
    uid = 1001;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ (lib.strings.trim (builtins.readFile ../keys/deploy.pub)) ];
  };

  # deploy may run nixos-rebuild's activation non-interactively.
  security.sudo.extraRules = [{
    users = [ "deploy" ];
    commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
  }];

  environment.systemPackages = with pkgs; [
    git vim htop tmux iproute2 iptables ethtool pciutils usbutils
    dnsutils curl jq
  ];
}
```

- [ ] **Step 2: Generate the dedicated deploy key and write its pubkey**

Run (on the workstation; private key stays in `~/.ssh`, only the pubkey enters the repo):
```bash
ssh-keygen -t ed25519 -N "" -C "deploy@gentoo-cluster" -f ~/.ssh/gentoo_deploy_ed25519
mkdir -p /home/slowking/Github/homelab/nixos/keys
cp ~/.ssh/gentoo_deploy_ed25519.pub /home/slowking/Github/homelab/nixos/keys/deploy.pub
cat /home/slowking/Github/homelab/nixos/keys/deploy.pub
```
Expected: prints one `ssh-ed25519 … deploy@gentoo-cluster` line; `nixos/keys/deploy.pub` exists.

- [ ] **Step 3: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/modules/common.nix nixos/keys/deploy.pub
git -C /home/slowking/Github/homelab commit -m "nixos: common module (users, deploy NOPASSWD sudo, nix settings)"
```

---

### Task 4: `modules/security.nix` — sshd hardening, firewall base, fail2ban, apparmor, tailscale

**Files:**
- Create: `nixos/modules/security.nix`

**Interfaces:**
- Consumes: nothing.
- Produces: `openssh` hardened, `networking.firewall` base (trusted `cni0`/`tailscale0`, pod/service CIDRs accepted, `checkReversePath="loose"`). Role modules (Task 7) add per-role `allowedTCPPorts`.

- [ ] **Step 1: Write the module**

`nixos/modules/security.nix`:
```nix
{ lib, ... }:
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.fail2ban = {
    enable = true;
    maxretry = 5;
  };

  security.apparmor.enable = true;  # NixOS-supported LSM (SELinux is not the NixOS default path)

  services.tailscale.enable = true;

  networking.firewall = {
    enable = true;
    checkReversePath = "loose";          # WiFi roaming + Tailscale asymmetric paths
    trustedInterfaces = [ "cni0" "tailscale0" ];
    extraInputRules = ''
      ip saddr 10.42.0.0/16 accept comment "k3s pod CIDR"
      ip saddr 10.43.0.0/16 accept comment "k3s service CIDR"
    '';
    # allowedTCPPorts are added per role in k3s-server.nix / k3s-agent.nix
  };
}
```

- [ ] **Step 2: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/modules/security.nix
git -C /home/slowking/Github/homelab commit -m "nixos: security module (sshd hardening, firewall base, fail2ban, apparmor, tailscale)"
```

---

### Task 5: `modules/networking.nix` — static WiFi via wpa_supplicant + sops PSK, extraHosts

**Files:**
- Create: `nixos/modules/networking.nix`

**Interfaces:**
- Consumes: `config.sops.secrets."wifi/env"` (declared in Task 8) via `environmentFile`, and `../assets/wifi-ssid.txt` (public, written in Task 8) via `readFile` for the literal SSID. Reads the WiFi iface and static IP from `homelab.node.*` set in `hosts/<n>/default.nix`.
- Produces: the `homelab.node` options module, `wpa_supplicant` bound to the host's WiFi iface, static IPv4, `extraHosts` for the internal registry.

- [ ] **Step 1: Write the module**

`nixos/modules/networking.nix`:
```nix
{ config, lib, ... }:
let
  cfg = config.homelab.node;
in
{
  options.homelab.node = {
    wifiInterface = lib.mkOption { type = lib.types.str; description = "WiFi interface name"; };
    ipv4 = lib.mkOption { type = lib.types.str; description = "Static IPv4 address (no prefix)"; };
  };

  config = {
    networking.useDHCP = false;
    networking.wireless = {
      enable = true;
      interfaces = [ cfg.wifiInterface ];
      # SSID is a literal (broadcast, not secret) read from a committed public file.
      # Only the PSK is kept out of the store: `ext:WIFI_PSK` pulls it at service
      # start from the sops-provided environmentFile, which defines `WIFI_PSK=…`.
      environmentFile = config.sops.secrets."wifi/env".path;
      networks.${lib.strings.trim (builtins.readFile ../assets/wifi-ssid.txt)}.pskRaw =
        "ext:WIFI_PSK";
    };

    networking.interfaces.${cfg.wifiInterface}.ipv4.addresses = [
      { address = cfg.ipv4; prefixLength = 24; }
    ];
    networking.defaultGateway = "192.168.1.1";
    networking.nameservers = [ "192.168.1.1" ];

    # Resolve the internal registry / ingress before in-cluster DNS exists.
    networking.extraHosts = ''
      192.168.1.25 registry.gentoo.lan
      192.168.1.25 gentoo.lan
      192.168.1.25 argocd.gentoo.lan
    '';
  };
}
```

> Note: `networking.wireless.environmentFile` substitutes `@WIFI_SSID@`/`@WIFI_PSK@` at service start from the sops file, so neither the SSID nor PSK is in the Nix store.

- [ ] **Step 2: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/modules/networking.nix
git -C /home/slowking/Github/homelab commit -m "nixos: networking module (static WiFi via wpa_supplicant + sops, extraHosts)"
```

---

### Task 6: `modules/k3s-common.nix` — Longhorn prereqs, registry config, internal CA

**Files:**
- Create: `nixos/modules/k3s-common.nix`
- Create: `nixos/assets/registries.yaml`
- Create: `nixos/assets/gentoo-internal-ca.crt`

**Interfaces:**
- Consumes: nothing.
- Produces: `services.openiscsi` enabled, `/etc/rancher/k3s/registries.yaml` + CA cert in `environment.etc`, Longhorn kernel modules + `nfs-utils`. Role modules set `services.k3s.role`.

- [ ] **Step 1: Write the registry mirror config asset**

`nixos/assets/registries.yaml`:
```yaml
mirrors:
  registry.gentoo.lan:
    endpoint:
      - "http://registry.gentoo.lan"
configs:
  "registry.gentoo.lan":
    tls:
      ca_file: /etc/rancher/k3s/certs/gentoo-internal-ca.crt
```

- [ ] **Step 2: Write the internal CA cert asset (public)**

`nixos/assets/gentoo-internal-ca.crt`:
```
-----BEGIN CERTIFICATE-----
MIIBfzCCASSgAwIBAgIUVaKGZaLbSAYuVAefnweeBQxCFlEwCgYIKoZIzj0EAwIw
HTEbMBkGA1UEAxMSZ2VudG9vLWludGVybmFsLWNhMB4XDTI2MDUyMTEyMzAxNloX
DTI2MDgxOTEyMzAxNlowHTEbMBkGA1UEAxMSZ2VudG9vLWludGVybmFsLWNhMFkw
EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEdGYAmC/YXjITLC1RHcDYM3/x7N/yxOFS
VBm1f9e24ItBeFsBJSN/aK0DEfxGAuT9PjpsG9p2Znln/ep559swEaNCMEAwDgYD
VR0PAQH/BAQDAgKkMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFDsMZQd0BmfG
VpvKrMacLVGT5cskMAoGCCqGSM49BAMCA0kAMEYCIQDGr/nQDV53CP5XMuTkkpsr
7EjKGT/uokbdrvW0pdjJrAIhAPHnUbNmyOCDP0028ryo4yTPqP0yiyMlIZZYPSlc
nLxl
-----END CERTIFICATE-----
```

> Note: the mirror endpoint is plain HTTP, so this CA is **not on the image-pull hot path** and its 2026-08-19 expiry does not block pulls; it reproduces current node state. If the mirror is ever switched to HTTPS, this file must be refreshed from the rotating cert-manager CA.

- [ ] **Step 3: Write the module**

`nixos/modules/k3s-common.nix`:
```nix
{ pkgs, ... }:
{
  services.openiscsi = {
    enable = true;
    name = "iqn.2020-01.io.homelab:node";  # stable initiator name for Longhorn
  };

  # Longhorn runtime deps.
  boot.kernelModules = [ "iscsi_tcp" "br_netfilter" "overlay" "dm_crypt" ];
  environment.systemPackages = [ pkgs.nfs-utils pkgs.openiscsi ];
  services.rpcbind.enable = true;  # NFS client for Longhorn RWX/backup mounts

  environment.etc."rancher/k3s/registries.yaml".source = ../assets/registries.yaml;
  environment.etc."rancher/k3s/certs/gentoo-internal-ca.crt".source =
    ../assets/gentoo-internal-ca.crt;
}
```

- [ ] **Step 4: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/modules/k3s-common.nix nixos/assets/registries.yaml nixos/assets/gentoo-internal-ca.crt
git -C /home/slowking/Github/homelab commit -m "nixos: k3s-common module (open-iscsi, registry mirror, internal CA, longhorn deps)"
```

---

### Task 7: `modules/k3s-server.nix` and `modules/k3s-agent.nix` — roles + firewall ports

**Files:**
- Create: `nixos/modules/k3s-server.nix`
- Create: `nixos/modules/k3s-agent.nix`

**Interfaces:**
- Consumes: `config.sops.secrets."k3s/token".path` (Task 8). `hosts/<n>/default.nix` imports exactly one of these.
- Produces: `services.k3s` fully configured for the role, plus per-role `networking.firewall.allowedTCPPorts`.

- [ ] **Step 1: Write the server module**

`nixos/modules/k3s-server.nix`:
```nix
{ config, ... }:
{
  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.sops.secrets."k3s/token".path;
    extraFlags = [
      "--flannel-backend=host-gw"
      "--node-name=cachyos"
      "--tls-san=192.168.1.31"
      "--tls-san=k3s.gentoo.lan"
      "--write-kubeconfig-mode=0644"
    ];
  };

  # API server, kubelet metrics, and servicelb/traefik ingress (live on both nodes today).
  networking.firewall.allowedTCPPorts = [ 6443 10250 80 443 ];
}
```

- [ ] **Step 2: Write the agent module**

`nixos/modules/k3s-agent.nix`:
```nix
{ config, ... }:
{
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://192.168.1.31:6443";
    tokenFile = config.sops.secrets."k3s/token".path;
  };

  networking.firewall.allowedTCPPorts = [ 10250 80 443 ];
}
```

- [ ] **Step 3: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/modules/k3s-server.nix nixos/modules/k3s-agent.nix
git -C /home/slowking/Github/homelab commit -m "nixos: k3s server + agent role modules with per-role firewall ports"
```

---

### Task 8: sops-nix — age keys, host keys, sealed secrets, sops module wiring

**Files:**
- Create: `nixos/.sops.yaml`
- Create: `nixos/secrets/cluster.yaml` (sops-encrypted)
- Create: `nixos/secrets/hosts/cachyos.yaml`, `nixos/secrets/hosts/tux.yaml` (sops-encrypted)
- Create: `nixos/assets/wifi-ssid.txt` (public — consumed by Task 5's networking module)
- Create: `nixos/modules/sops.nix`
- Modify: `nixos/flake.nix` (add `./modules/sops.nix` to `mkNode` module list)

**Interfaces:**
- Consumes: sealed values.
- Produces: `config.sops.secrets."k3s/token"`, `"wifi/env"` (an env file defining `WIFI_PSK`, consumed in Task 5), `"slowking/hashed-password"` (consumed in Task 3), `"ssh_host_ed25519_key"`. The host private key is delivered at install via `--extra-files`; its public half's age recipient decrypts everything else.

- [ ] **Step 1: Generate the workstation age key and per-host SSH host keys**

Run:
```bash
mkdir -p ~/.config/sops/age /home/slowking/Github/homelab/nixos/keys
[ -f ~/.config/sops/age/keys.txt ] || age-keygen -o ~/.config/sops/age/keys.txt
WS_AGE=$(age-keygen -y ~/.config/sops/age/keys.txt); echo "workstation age: $WS_AGE"

cd /home/slowking/Github/homelab/nixos/keys
for h in cachyos tux; do
  ssh-keygen -t ed25519 -N "" -C "root@$h" -f ${h}_ssh_host_ed25519_key
done
nix shell nixpkgs#ssh-to-age --command bash -c '
  for h in cachyos tux; do
    echo "$h age: $(ssh-to-age -i ${h}_ssh_host_ed25519_key.pub)"
  done'
```
Expected: prints the workstation age recipient and each host's age recipient (`age1…`). The `*_ssh_host_ed25519_key` private files are git-ignored (Task 1).

- [ ] **Step 2: Write `.sops.yaml` with the three recipients**

Replace `AGE_WS`, `AGE_CACHYOS`, `AGE_TUX` with the values printed in Step 1.

`nixos/.sops.yaml`:
```yaml
keys:
  - &ws AGE_WS
  - &cachyos AGE_CACHYOS
  - &tux AGE_TUX
creation_rules:
  - path_regex: secrets/cluster\.yaml$
    key_groups:
      - age: [*ws, *cachyos, *tux]
  - path_regex: secrets/hosts/cachyos\.yaml$
    key_groups:
      - age: [*ws, *cachyos]
  - path_regex: secrets/hosts/tux\.yaml$
    key_groups:
      - age: [*ws, *tux]
```

- [ ] **Step 3: Extract WiFi creds, write the public SSID, seal cluster secrets**

Run (SSID → committed public file; PSK, k3s token, slowking password → sops):
```bash
cd /home/slowking/Github/homelab/nixos
mkdir -p assets
SSID=$(ssh slowking@cachyos-x8664 'echo thanas24 | sudo -S grep -h "^ssid=" /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | head -1 | cut -d= -f2')
PSK=$(ssh slowking@cachyos-x8664 'echo thanas24 | sudo -S grep -h "^psk=" /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | head -1 | cut -d= -f2')
printf '%s' "$SSID" > assets/wifi-ssid.txt          # public: SSID is broadcast, not secret
TOKEN=$(openssl rand -hex 32)
PWHASH=$(nix shell nixpkgs#mkpasswd --command mkpasswd -m sha-512)   # prompts for slowking's password
umask 077
cat > /tmp/cluster.plain.yaml <<EOF
k3s:
  token: ${TOKEN}
wifi:
  env: |
    WIFI_PSK=${PSK}
slowking:
  hashed-password: "${PWHASH}"
EOF
sops --encrypt /tmp/cluster.plain.yaml > secrets/cluster.yaml
shred -u /tmp/cluster.plain.yaml
```
Expected: `assets/wifi-ssid.txt` holds the SSID; `secrets/cluster.yaml` is sops-encrypted. Confirm no plaintext leaked: `grep -c "WIFI_PSK=${PSK}" secrets/cluster.yaml` → `0`. The `wifi.env` value is exactly `WIFI_PSK=<psk>\n`, usable directly as wpa_supplicant's `environmentFile`.

- [ ] **Step 4: Seal each host's SSH host private key**

Run:
```bash
cd /home/slowking/Github/homelab/nixos
mkdir -p secrets/hosts
for h in cachyos tux; do
  sops --encrypt --input-type binary --output-type yaml \
    <(printf 'ssh_host_ed25519_key: |\n'; sed 's/^/  /' keys/${h}_ssh_host_ed25519_key) \
    > secrets/hosts/${h}.yaml
done
grep -c 'PRIVATE KEY' secrets/hosts/cachyos.yaml
```
Expected: `secrets/hosts/*.yaml` are sops-encrypted; the `grep` prints `0` (key is encrypted, not plaintext).

- [ ] **Step 5: Write the sops module**

`nixos/modules/sops.nix`:
```nix
{ config, ... }:
{
  sops.defaultSopsFile = ../secrets/cluster.yaml;
  # The age key used to decrypt at runtime IS the machine's SSH host key,
  # delivered to /etc/ssh/ssh_host_ed25519_key at install via nixos-anywhere --extra-files.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets."k3s/token" = { };
  sops.secrets."wifi/env" = { };
  sops.secrets."slowking/hashed-password" = { neededForUsers = true; };

  # Host key also sealed per-host so `nixos-rebuild switch` can restore it if lost.
  sops.secrets."ssh_host_ed25519_key" = {
    sopsFile = ../secrets/hosts/${config.networking.hostName}.yaml;
    path = "/etc/ssh/ssh_host_ed25519_key";
    mode = "0600";
    neededForUsers = false;
  };
}
```

- [ ] **Step 6: Add the sops module to the flake**

In `nixos/flake.nix`, add `./modules/sops.nix` to the `mkNode` `modules` list (right after `sops-nix.nixosModules.sops`).

```nix
            sops-nix.nixosModules.sops
            ./modules/sops.nix
```

- [ ] **Step 7: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/.sops.yaml nixos/secrets nixos/modules/sops.nix nixos/flake.nix
git -C /home/slowking/Github/homelab commit -m "nixos: sops-nix secrets (k3s token, wifi, host keys) and module wiring"
```

---

### Task 9: `hosts/cachyos/` — server node (default, disko, hardware)

**Files:**
- Create: `nixos/hosts/cachyos/default.nix`
- Create: `nixos/hosts/cachyos/disko.nix`
- Create: `nixos/hosts/cachyos/hardware.nix`

**Interfaces:**
- Consumes: `homelab.node.{wifiInterface,ipv4}` (Task 5), `./modules/k3s-server.nix` (Task 7).
- Produces: `nixosConfigurations.cachyos` fully evaluable.

- [ ] **Step 1: Write the node config**

`nixos/hosts/cachyos/default.nix`:
```nix
{ ... }:
{
  imports = [ ../../modules/k3s-server.nix ];

  networking.hostName = "cachyos";
  homelab.node = {
    wifiInterface = "wlan0";
    ipv4 = "192.168.1.31";
  };

  # Sole control plane — a closed lid must not suspend the node.
  services.logind.lidSwitch = "ignore";
  services.logind.lidSwitchExternalPower = "ignore";

  system.stateVersion = "25.11";
}
```

- [ ] **Step 2: Write the disko layout (single NVMe → ESP + XFS root)**

`nixos/hosts/cachyos/disko.nix`:
```nix
{ ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-SAMSUNG_MZAL4256HBJD-00BL2_S67PNF0W869279";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; };
        };
        root = {
          size = "100%";
          content = { type = "filesystem"; format = "xfs"; mountpoint = "/"; };
        };
      };
    };
  };
}
```

- [ ] **Step 3: Write a baseline hardware config**

`nixos/hosts/cachyos/hardware.nix`:
```nix
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  # Baseline — nixos-anywhere regenerates/refines this at install (--generate-hardware-config).
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;
  nixpkgs.hostPlatform = "x86_64-linux";
}
```

- [ ] **Step 4: Verify `cachyos` evaluates and builds**

Run:
```bash
cd /home/slowking/Github/homelab && git add nixos/hosts/cachyos
nix eval ./nixos#nixosConfigurations.cachyos.config.services.k3s.role --raw
nix build ./nixos#nixosConfigurations.cachyos.config.system.build.toplevel --no-link
```
Expected: `nix eval` prints `server`; `nix build` completes without error (proves modules + host + disko + sops declarations all evaluate and the closure builds).

- [ ] **Step 5: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/hosts/cachyos
git -C /home/slowking/Github/homelab commit -m "nixos: cachyos server node (disko XFS, wlan0 static, lid=ignore)"
```

---

### Task 10: `hosts/tux/` — agent node (default, disko, hardware)

**Files:**
- Create: `nixos/hosts/tux/default.nix`
- Create: `nixos/hosts/tux/disko.nix`
- Create: `nixos/hosts/tux/hardware.nix`

**Interfaces:**
- Consumes: `homelab.node.*` (Task 5), `./modules/k3s-agent.nix` (Task 7).
- Produces: `nixosConfigurations.tux` fully evaluable.

- [ ] **Step 1: Write the node config**

`nixos/hosts/tux/default.nix`:
```nix
{ ... }:
{
  imports = [ ../../modules/k3s-agent.nix ];

  networking.hostName = "tux";
  homelab.node = {
    wifiInterface = "wlp1s0";
    ipv4 = "192.168.1.25";
  };

  system.stateVersion = "25.11";
}
```

- [ ] **Step 2: Write the disko layout (single SATA M.2 → ESP + XFS root)**

`nixos/hosts/tux/disko.nix`:
```nix
{ ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/ata-SanDisk_X400_M.2_2280_256GB_170717803474";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; };
        };
        root = {
          size = "100%";
          content = { type = "filesystem"; format = "xfs"; mountpoint = "/"; };
        };
      };
    };
  };
}
```

- [ ] **Step 3: Write a baseline hardware config**

`nixos/hosts/tux/hardware.nix`:
```nix
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "usb_storage" "sd_mod" "nvme" ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
  nixpkgs.hostPlatform = "x86_64-linux";
}
```

- [ ] **Step 4: Verify `tux` evaluates and builds**

Run:
```bash
cd /home/slowking/Github/homelab && git add nixos/hosts/tux
nix eval ./nixos#nixosConfigurations.tux.config.services.k3s.role --raw
nix eval ./nixos#nixosConfigurations.tux.config.services.k3s.serverAddr --raw
nix build ./nixos#nixosConfigurations.tux.config.system.build.toplevel --no-link
```
Expected: prints `agent`, then `https://192.168.1.31:6443`; `nix build` completes without error.

- [ ] **Step 5: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/hosts/tux
git -C /home/slowking/Github/homelab commit -m "nixos: tux agent node (disko XFS, wlp1s0 static, joins server)"
```

---

### Task 11: Whole-flake verification

**Files:** none (verification only).

- [ ] **Step 1: Assert key invariants across both nodes**

Run:
```bash
cd /home/slowking/Github/homelab
# firewall ports per role
nix eval ./nixos#nixosConfigurations.cachyos.config.networking.firewall.allowedTCPPorts --json
nix eval ./nixos#nixosConfigurations.tux.config.networking.firewall.allowedTCPPorts --json
# admin key preserved on both
nix eval --json ./nixos#nixosConfigurations.tux.config.users.users.slowking.openssh.authorizedKeys.keys | grep -c 'thanas.papa.24@gmail.com'
# static IPs
nix eval ./nixos#nixosConfigurations.cachyos.config.networking.interfaces.wlan0.ipv4.addresses --json
```
Expected: cachyos ports `[6443,10250,80,443]`; tux ports `[10250,80,443]`; grep count ≥ 1; cachyos address shows `192.168.1.31/24`.

- [ ] **Step 2: Full flake check**

Run:
```bash
nix flake check ./nixos
```
Expected: no errors (both `nixosConfigurations` evaluate).

- [ ] **Step 3: Commit (lockfile refresh if any)**

```bash
git -C /home/slowking/Github/homelab add nixos/flake.lock
git -C /home/slowking/Github/homelab commit -m "nixos: whole-flake verification passes" --allow-empty
```

---

### Task 12: `nixos/README.md` — install + deploy runbook

**Files:**
- Create: `nixos/README.md`

- [ ] **Step 1: Write the runbook**

`nixos/README.md`:
````markdown
# gentoo cluster — NixOS node flake

Manages the k3s nodes: `cachyos` (server, 192.168.1.31) and `tux` (agent, 192.168.1.25).
All commands run from the NixOS workstation. `git add` new files before any `nix` command
(flakes ignore untracked files).

## Prerequisites
- Workstation age key at `~/.config/sops/age/keys.txt` (a `.sops.yaml` recipient).
- Deploy key `~/.ssh/gentoo_deploy_ed25519` (its pubkey is `nixos/keys/deploy.pub`).
- Per-host SSH host private keys under `nixos/keys/<host>_ssh_host_ed25519_key` (git-ignored).

## Remote install (destructive — migration window only)

⚠️ Both nodes are WiFi-only. `nixos-anywhere`'s kexec installer can drop the WiFi link
mid-install. Do the install with a **temporary USB-ethernet dongle** on the node (both nodes
are down together during the migration), then reconnect WiFi via the deployed config. This is
the recommended path. (Alternative: build a per-node installer ISO with WiFi baked in.)

Only run this AFTER the migration backup phase (Velero + Vault snapshot) is complete.

Per host (`<host>` = `cachyos` or `tux`, `<ip>` its address, currently reachable as root or
via a rescue environment):

```bash
cd nixos
nix run github:nix-community/nixos-anywhere -- \
  --flake .#<host> \
  --generate-hardware-config nixos-generate-config ./hosts/<host>/hardware.nix \
  --extra-files-owner root:root \
  --extra-files ./install-extra/<host> \
  --target-host root@<ip>
```

Where `./install-extra/<host>/etc/ssh/ssh_host_ed25519_key` is a 0600 copy of
`keys/<host>_ssh_host_ed25519_key` (this seeds the machine's identity so sops can decrypt on
first boot). Create it just before install:

```bash
install -Dm600 keys/<host>_ssh_host_ed25519_key install-extra/<host>/etc/ssh/ssh_host_ed25519_key
```

`install-extra/` is git-ignored. After install, commit the refreshed
`hosts/<host>/hardware.nix` that `nixos-anywhere` regenerated.

## Remote deploy (config changes)

```bash
cd nixos
nixos-rebuild switch --flake .#<host> \
  --target-host deploy@<ip> --use-remote-sudo
```

Builds on the workstation and pushes closures (tux is too weak to build locally). Add
`--build-host ""` is unnecessary; the default already builds on the local workstation.

## Adding a node (3–6)
1. `hosts/<new>/{default,disko,hardware}.nix` (copy tux's agent files; set hostName, IP, iface, disk by-id).
2. Add `<new> = mkNode "<new>";` to `flake.nix`.
3. Generate a host key + age recipient, add to `.sops.yaml`, re-encrypt `secrets/cluster.yaml`
   (`sops updatekeys secrets/cluster.yaml`), seal `secrets/hosts/<new>.yaml`.
4. `nix build .#nixosConfigurations.<new>.config.system.build.toplevel`, then install as above.

## Integration with the cluster rebuild
This produces "k3s running on NixOS". Then follow Phase 4 of
`docs/superpowers/specs/2026-07-21-nixos-migration-backup-restore-design.md`: bootstrap Argo CD
→ infra syncs in sync-wave order → re-add Velero → `velero restore` PVCs → unseal Vault.
````

- [ ] **Step 2: Commit**

```bash
git -C /home/slowking/Github/homelab add nixos/README.md
git -C /home/slowking/Github/homelab commit -m "nixos: install + deploy runbook"
```

---

## Notes for the executor
- **Do not** run `nixos-anywhere` or `nixos-rebuild switch` against the live nodes as part of executing this plan — those are the migration window and are gated on backups. This plan is complete when the flake evaluates, both `toplevel` closures build, secrets are sealed, and the runbook exists.
- If `nix build` of a `toplevel` fails on a missing option (e.g. a `services.k3s` option renamed between nixpkgs releases), check the `nixos-25.11` module docs for the current option name and adjust — do not downgrade the pin without noting it.
- The `hardware.nix` files are baselines; the real ones come from `--generate-hardware-config` at install and should be committed afterward.
