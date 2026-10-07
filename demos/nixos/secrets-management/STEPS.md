## Steps to take for the demo

Hi! This is the step-by-step guide for running the sops-nix secrets management demo! Here I will be demonstrating how we can create, read, edit, store and provide secrets for our nodes to consume securely. Instead of real-life nodes, I'll be using VMs here, since that will be easier for a demo.

First, enter the dev environment using nix:
```bash
nix develop
```
You should see something like:

```bash
❯ nix develop
You've entered the dev environment for the sops-nix secrets demo!

[slowking@nixos:~/Github/homelab/demos/nixos/secrets-management]$
```

Next, we need to create an age key for sops to use on our local machine:

```bash
age-keygen -o keys/admin.txt
```

It should look like:

```bash
[slowking@nixos:~/Github/homelab/demos/nixos/secrets-management]$ age-keygen -o keys/admin.txt
Public key: age1xz5s5yaqyvam6uhe3a0j98790l8ckvw2cem498l5vjlyc2t24snqhyd9dc
```

And now we need SSH keys for each VM:

```bash
ssh-keygen -t ed25519 -f keys/vm-a -N '' -C vm-a-host
ssh-keygen -t ed25519 -f keys/vm-b -N '' -C vm-b-host
```

This should have printed a result like:

```bash
[slowking@nixos:~/Github/homelab/demos/nixos/secrets-management]$ ssh-keygen -t ed25519 -f keys/vm-a -N '' -C vm-a-host
Generating public/private ed25519 key pair.
Your identification has been saved in keys/vm-a
Your public key has been saved in keys/vm-a.pub
The key fingerprint is:
SHA256:9GCBFpBe4KGL3XtwfBbb6eo0Rd3xeBWRLSEu76/KA4g vm-a-host
The key's randomart image is:
+--[ED25519 256]--+
|    ++.o.   . o+*|
|   o..+  . o o.=o|
|  ...o  = o o o.o|
| o o.. o B +   . |
|. o o.o.S = .    |
|    E+.o.o .     |
|    . . o.. .    |
|     . . +.  .   |
|       .o oo...  |
+----[SHA256]-----+

[slowking@nixos:~/Github/homelab/demos/nixos/secrets-management]$ ssh-keygen -t ed25519 -f keys/vm-b -N '' -C vm-b-host
Generating public/private ed25519 key pair.
Your identification has been saved in keys/vm-b
Your public key has been saved in keys/vm-b.pub
The key fingerprint is:
SHA256:RjXYlEftvavZR3h9CAA/ev6IOF6pKjdEgPwDvb5rnVU vm-b-host
The key's randomart image is:
+--[ED25519 256]--+
|...     .=+o..   |
|.o..    .o+.. .  |
|  o..   . oo . . |
|   +.  . E .. . .|
|  ...   S .  . oo|
|   ..  o +    o.=|
|   .o o o .    oo|
|  .ooo.+ . o  o..|
|  .+o++.. . .o...|
+----[SHA256]-----+
```

So far, what we have created is: an age private key for our machine, and 2 SSH keys for the VMs.

Our approach will be to use the SSH keys as age keys. When writing our secrets that will then be fed to our VMs, we need to encrypt the secrets with the public key of each VM, so that they can then be decrypted by each VM independently. Before we feed them into our nodes, we will need to write our secrets and a `.sops.yaml` file, which will let us introduce structure, and for that to happen we need a way to encrypt our secrets for us and for our VMs. This will require public age keys, which I'll generate now:

```bash
age-keygen -y keys/admin.txt # Generating a public key from our machine's private key
ssh-to-age -i keys/vm-a.pub # Converting the SSH public key into an age public key
ssh-to-age -i keys/vm-b.pub # Same thing here but for the other node
```

The result should look like:

```bash
[slowking@nixos:~/Github/homelab/demos/nixos/secrets-management]$  age-keygen -y keys/admin.txt
age1xz5s5yaqyvam6uhe3a0j98790l8ckvw2cem498l5vjlyc2t24snqhyd9dc

[slowking@nixos:~/Github/homelab/demos/nixos/secrets-management]$ ssh-to-age -i keys/
admin.txt   .gitignore  vm-a        vm-a.pub    vm-b        vm-b.pub

[slowking@nixos:~/Github/homelab/demos/nixos/secrets-management]$ ssh-to-age -i keys/vm-a.pub
age17ckhk6w3ayx59t585yamfrajvk3t9nl20xd38xzv6454jy7n0f6sxrwq2l

[slowking@nixos:~/Github/homelab/demos/nixos/secrets-management]$ ssh-to-age -i keys/vm-b.pub
age10nq3z9zd9dd222fxr58g664eg4cus64jn6s6krm2nptsfwry8u9srzeq6g
```

Now we can write the `.sops.yaml` file! It should look something like:

```yaml
keys:
  - &us age1xz5s5yaqyvam6uhe3a0j98790l8ckvw2cem498l5vjlyc2t24snqhyd9dc
  - &vm-a age17ckhk6w3ayx59t585yamfrajvk3t9nl20xd38xzv6454jy7n0f6sxrwq2l
  - &vm-b age10nq3z9zd9dd222fxr58g664eg4cus64jn6s6krm2nptsfwry8u9srzeq6g
creation_rules:
  - path_regex: secrets/demo\.yaml$
    key_groups:
      - age: [*us, *vm-a, *vm-b]
  - path_regex: secrets/hosts/vm-a\.yaml$
    key_groups:
      - age: [*us, *vm-a]
  - path_regex: secrets/hosts/vm-b\.yaml$
    key_groups:
      - age: [*us, *vm-b]
```
And our file structure by now should look something like:

```bash
.
├── flake.lock
├── flake.nix
├── keys
│   ├── admin.txt
│   ├── vm-a
│   ├── vm-a.pub
│   ├── vm-b
│   └── vm-b.pub
├── secrets
│   ├── demo.yaml
│   └── hosts
│       ├── vm-a.yaml
│       └── vm-b.yaml
└── STEPS.md
```

Don't worry about the yaml files within the `secrets` folder, we'll get to them. Right now we have structured our `.sops.yaml` file such that writing secrets will give us ciphertext encrypted with the public keys of the relevant machines, so each machine can understand what belongs to it. We will have general secrets all machines should know within `secrets/demo.yaml`, and then machine-specific secrets within each host's yaml file. All should stay editable by `us`, which is the main workstation machine controlling everything.

We have two ways from here: either write the yaml files within the `sops` editor, or perform in-place encryption after writing the secrets in plaintext within the yaml files. Since this is documentation, I'll go ahead and use the second approach.

First we write secrets in plaintext:

```bash
echo 'api-token: demo-shared-token-12345\n'  > secrets/demo.yaml
echo 'password: vm-a-password' > secrets/hosts/vm-a.yaml
echo 'password: vm-b-password' > secrets/hosts/vm-b.yaml
```
This has been kept simple on purpose for demo reasons, but we could write more complex yaml syntax just as well. Now we encrypt each file:

```bash
sops encrypt --in-place secrets/demo.yaml
sops encrypt --in-place secrets/hosts/vm-a.yaml
sops encrypt --in-place secrets/hosts/vm-b.yaml
```
After encryption, we should be able to see yaml files whose values have been encrypted for each configured recipient. Let's have a look at our `secrets/demo.yaml`:

```yaml
api-token: ENC[AES256_GCM,data:/uUazT/aNGGajOcopU2eRhutGX2Bw1JvHg==,iv:wE8BL7B47ys/d/IMtfk835KIh/Z0M3KYlj0gTGFTSAQ=,tag:BKeHG+eLnc2IymArfvX6NQ==,type:str]
sops:
    age:
        - enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBCbkh2cVlxQ0FjRGJZVnBk
            TFZXSDlveS8rdjU5Y3oyMTlQejhHeWxWRzBjCm1yMGJvcUdGVkxGcis5Z2xiRXMy
            c2xzcWMrUldRdEtNSDRINitLdUFkRWsKLS0tIDlEeXZrNXVWQmh4WFM2MCszNmI1
            L0RLQTFJLzRuM2hFYWhOQm9yMWRvQmsK4bJnMthGYjGJzt2NcLEktp0Cf8yOuixV
            UZOAwFIWsZAyO77YpDM+1a++A1rq33jwvaNlgSqndUbDdpDqBjVDSQ==
            -----END AGE ENCRYPTED FILE-----
          recipient: age1xz5s5yaqyvam6uhe3a0j98790l8ckvw2cem498l5vjlyc2t24snqhyd9dc
        - enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBTcXNJUUhiNmMzYXZKbjNK
            OE43VDcySGxXSWppVkJzVGxqSjB1bk0rZVJFCllHMkUvVUFmcUNNNmY2bExyVERj
            bkdqRTlmN3hYbWtUWTV3bDZPUGFaeFkKLS0tIGJpUEloTW00U3BTOWp3WFBQRmEv
            eDA0UGRyTE5nSERvSUxaMlBZeFc4MlkK35R5+O64WGju0u3ZCA0rWV5l9UV3O+0J
            82O7MYOIatC/Z+csmRQgV/uSLecdHNpUohj2oz38o/HW+yDR1+qGrg==
            -----END AGE ENCRYPTED FILE-----
          recipient: age17ckhk6w3ayx59t585yamfrajvk3t9nl20xd38xzv6454jy7n0f6sxrwq2l
        - enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSA1STVRQmthL0V4QS9XYjVF
            YzFoOHZtL1pteXc3cnYyd0FqckM4UE1HQm1vCjhoTnA2VGxRczV3UU44OVArbjdJ
            dXZxUGJNMTZHMHBvdW5HQ3lNZ1FUN1kKLS0tIC9TNSt5WThzN2htc2tlNjM4VGpx
            MEFZT2puS0k0eWZOS1R0czJsRmNYRGcKoPYQCRVg2AuNhI3AjboT/Mj7w5zRI+eL
            f9PVMK+daZf+KGlV59fwe2gnhyXK2nsqvbkGyP/g5d6QZZ9FVwUj/Q==
            -----END AGE ENCRYPTED FILE-----
          recipient: age10nq3z9zd9dd222fxr58g664eg4cus64jn6s6krm2nptsfwry8u9srzeq6g
    lastmodified: "2026-10-06T21:16:06Z"
    mac: ENC[AES256_GCM,data:9afMizH1xEIUHTVyTDQPuoqPlgVejptWx/vFFcJXfAkH8a2fvqui6RxLxVTJFlX64Qo5Ozz9N6Sghk1fpO+yq4VLoN1H8snSuBWpW3P5gbhrPSx7Q29uU98Jyh/Wt0O1KPaKbyMvN0m9oJxYFSOIhcEyOGDaMI4FF+TczTHLgKM=,iv:0f19Txifd0Aiyy5MTj55KRo04tp1e/M8AHsezlzzsMw=,tag:LvgZlY8KpUW3387a6u0xGA==,type:str]
    unencrypted_suffix: _unencrypted
    version: 3.13.3
```
`api-token` is the key we provided when creating our secret in plaintext, the value has been replaced with encryption-related metadata, and there are 3 blocks, each containing encrypted data for every configured recipient! Now let's see if we can decrypt this data. We will be using the `sops -d secret.yaml` command for this. Such a command needs one environment variable that will tell sops what private key to use for decryption, so our command needs to be as follows:

```bash
export SOPS_AGE_KEY_FILE=keys/admin.txt

sops -d secrets/demo.yaml
api-token: demo-shared-token-12345\n
```

So far so good!

Now, we need to provide our VMs with these secrets. To do this I have created a function within `flake.nix` which will create a NixOS configuration from .nix files. These .nix files reference the secrets found within our sops+age encrypted yaml files.

The function in `flake.nix` is as follows:
```nix
mkVm = hostName:
  nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      sops-nix.nixosModules.sops
      ./vm-common.nix
      ./vm-${hostName}.nix
    ];
  };
```
This function takes a string as its argument and creates a NixOS configuration from it. The way I have used it is:

```nix
nixosConfigurations = {
  vm-a = mkVm "a";
  vm-b = mkVm "b";
};
```
So I have created 2 configurations, one for each VM we'll be testing, which are built based on hostname-specific configurations.

Within `vm-common.nix` I have set the sops age identity to be the machine's private SSH key, which is the private SSH key we generated earlier, and then referenced the commonly accessible `api-token` secret from before.

`vm-common.nix`
```nix
{ ... }:
{
  system.stateVersion = "26.05";
  services.getty.autologinUser = "root";
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets."api-token".sopsFile = ./secrets/demo.yaml;
}
```
Within the hostname-specific configurations I have set the per-host secrets:

`vm-a.nix`
```nix
{ ... }:
{
  networking.hostName = "vm-a";

  environment.etc."ssh/ssh_host_ed25519_key".source = ./keys/vm-a;
  environment.etc."ssh/ssh_host_ed25519_key.pub".source = ./keys/vm-a.pub;

  # name = filename in /run/secrets/, key = which YAML key to extract
  sops.secrets."db-password" = {
    sopsFile = ./secrets/hosts/vm-a.yaml;
    key = "password";
  };
}
```

`vm-b.nix` is almost identical


Now we need to build the configuration of the first VM:

```bash
nix build .#nixosConfigurations.vm-a.config.system.build.vm -o result-vm-a
```

And after that's done, let's run it!:

```bash
 ./result-vm-a/bin/run-vm-a-vm
Disk image does not exist, creating the virtualisation disk image...
Formatting '/tmp/nix-shell.djpDUM/tmp.tNAyBLfod7', fmt=raw size=1073741824
mke2fs 1.47.4 (6-Mar-2025)
Discarding device blocks: done
Creating filesystem with 262144 4k blocks and 65536 inodes
Filesystem UUID: 74132695-f63b-4d25-bd11-2a4818bde805
Superblock backups stored on blocks:
        32768, 98304, 163840, 229376

Allocating group tables: done
Writing inode tables: done
Creating journal (8192 blocks): done
Writing superblocks and filesystem accounting information: done

Virtualisation disk image created.
```

This will hopefully have created a VM window on your screen. Now that you're inside `vm-a`, there should hopefully be a `/run/secrets` directory which contains what we gave it. Try the following:

```bash
ls /run/secrets
api-token db-password
```
Now if we cat their content:

```bash
cat /run/secrets/api-token
demo-shared-token-12345\n

cat /run/secrets/db-password
vm-a-password
```
We can see that everything has been correctly provided to our node as planned! Doing the same thing with vm-b should have the same result.


This concludes our demo!
