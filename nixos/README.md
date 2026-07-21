# gentoo cluster — NixOS node flake

Manages the k3s nodes: `cachyos` (server, 192.168.1.31) and `tux` (agent, 192.168.1.25).
All commands run from the NixOS workstation. **`git add` new files before any `nix` command**
(flakes ignore untracked files).

## Prerequisites
- Workstation age key at `~/.config/sops/age/keys.txt` (a `.sops.yaml` recipient).
- Deploy key `~/.ssh/gentoo_deploy_ed25519` (its pubkey is `nixos/keys/deploy.pub`).
- Per-host SSH host private keys under `nixos/keys/<host>_ssh_host_ed25519_key` (git-ignored).

## Rotating the `slowking` login password (optional)

`secrets/cluster.yaml` already holds a sealed `slowking` password hash (initialized to the
node's existing password). It is the console/interactive-`sudo` credential; SSH is key-only
regardless. To change it, run in your own terminal so the new password never leaves your shell:

```bash
cd nixos
HASH=$(nix shell nixpkgs#mkpasswd --command mkpasswd -m sha-512)   # prompts for the new password
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops set secrets/cluster.yaml '["slowking"]["hashed-password"]' "\"$HASH\""
git add secrets/cluster.yaml && git commit -m "nixos: rotate slowking password"
```

Then `nixos-rebuild switch` (below) to apply. The `deploy` user (NOPASSWD sudo, used for
deploys) is unaffected by this.

## Remote install (destructive — migration window only)

⚠️ Both nodes are WiFi-only. `nixos-anywhere`'s kexec installer can drop the WiFi link
mid-install. Do the install with a **temporary USB-ethernet dongle** on the node (both nodes
are down together during the migration), then reconnect WiFi via the deployed config. This is
the recommended path. (Alternative: build a per-node installer ISO with WiFi baked in.)

Only run this AFTER the migration backup phase (Velero + Vault snapshot) is complete.

Per host (`<host>` = `cachyos` or `tux`, `<ip>` its address, currently reachable as root or
via a rescue environment). First seed the machine's SSH host identity so sops can decrypt on
first boot:

```bash
cd nixos
install -Dm600 keys/<host>_ssh_host_ed25519_key install-extra/<host>/etc/ssh/ssh_host_ed25519_key
```

Then install (`install-extra/` is git-ignored):

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#<host> \
  --generate-hardware-config nixos-generate-config ./hosts/<host>/hardware.nix \
  --extra-files ./install-extra/<host> \
  --target-host root@<ip>
```

After install, commit the refreshed `hosts/<host>/hardware.nix` that `nixos-anywhere`
regenerated.

## Remote deploy (config changes)

```bash
cd nixos
nixos-rebuild switch --flake .#<host> \
  --target-host deploy@<ip> --use-remote-sudo
```

Builds on the workstation and pushes closures (tux is too weak to build locally).

## Adding a node (3–6)
1. `hosts/<new>/{default,disko,hardware}.nix` (copy `tux`'s agent files; set hostName, IP,
   iface, disk by-id).
2. Add `<new> = mkNode "<new>";` to `flake.nix`.
3. Generate a host key + age recipient, add to `.sops.yaml`, re-encrypt the shared secret
   (`sops updatekeys secrets/cluster.yaml`), seal `secrets/hosts/<new>.yaml`.
4. `nix build .#nixosConfigurations.<new>.config.system.build.toplevel`, then install as above.

## Integration with the cluster rebuild
This produces "k3s running on NixOS". Then follow Phase 4 of
`docs/superpowers/specs/2026-07-21-nixos-migration-backup-restore-design.md`: bootstrap Argo CD
→ infra syncs in sync-wave order → re-add Velero → `velero restore` PVCs → unseal Vault.
