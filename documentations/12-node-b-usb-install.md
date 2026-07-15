# 12 — node-B (offsite-1) install from a NixOS live USB

**Chosen method.** Boot the box from a NixOS installer USB (you have monitor +
keyboard), partition with `disko`, `nixos-install` the flake. This **replaces**
the `dd`/image-flash method in doc 11 — that one only existed because we assumed
the NVMe could be flashed from another machine. The NVMe is already in the box,
so we install in place. Standard, simplest, and it brings back two niceties:

- **disko runs live** → it can *prompt* for the ZFS passphrase at format time, so
  the encrypted datasets are declared in disko (the qemu image build couldn't
  prompt, hence doc 11's manual `zfs create`). **No key is ever stored on the box.**
- a real installer can write an EFI NVRAM boot entry → plain **systemd-boot**, no
  GRUB-removable workaround.
- both disks are formatted in **one `disko` run** → no post-boot HDD step.

**Box:** Lenovo ThinkCentre M715q Tiny (`10VGS05N00`), AMD PRO A10-9700E.
Disks: `nvme0n1` 500 GB (boot + meta + ssd-data) and `sda` 1 TB HDD (bulk data).
Role: storage **+** Tailscale subnet-router/exit-node proxy, zone `offsite-1`.

**Encryption posture (offsite):** root ext4 **unencrypted** so the box boots
unattended → sshd + tailscale come up → you unlock the encrypted **data** pools
*post-boot over the tailnet* with `zfs load-key -a`. Stolen box stays locked. The
one recurring manual step is that unlock after each reboot.

> Want it even simpler? Two opt-outs, both one-liners (see §9):
> **(a)** auto-unlock via sops (no per-reboot prompt, weaker offsite theft story),
> or **(b)** no data encryption at all. Default below = prompt-unlock.

---

## 0. What you need

- This NixOS box-to-be, with **monitor + keyboard** attached and wired ethernet.
- One USB stick for the **NixOS installer** (≥2 GB).
- A way to get `garage-fleet/` + the node's SSH host key onto the box. Simplest:
  a **second USB stick** (no GitHub creds needed on the box). Alt: `git clone`
  over HTTPS with a PAT (§4 note).
- Your **workstation** with `nix` (flakes on), `age-keygen`, `ssh-to-age`,
  `sops`, `openssl` — for §1.
- Your SSH **public** key (for break-glass admin + deploy).

Security invariants (unchanged from doc 09/10/11):
- ZFS passphrase **never** on the box — typed at format, then at each unlock; keep
  it offline in **two** physical locations.
- SSH host **private** key goes onto the box by direct copy to `/mnt/etc/ssh`,
  **never** through the Nix store.
- The `garage` user gets **zero** `zfs allow` (the snapshot moat depends on it).
- Fleet secrets are a **separate trust domain** — never reuse prod age keys.
- Every Garage listener binds the **tailscale0 overlay IP only**, never `0.0.0.0`.

---

## 1. Workstation: secrets + flake edits

All paths below are relative to `garage-fleet/`.

### 1.1 Mint fleet secrets

```bash
cd garage-fleet
./secrets/gen-secrets.sh        # prints fleet age RECIPIENT + rpc/admin/metrics
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/garage-fleet.txt"
```

Paste the printed `age1…` **recipient** into `.sops.yaml` replacing the
`age1FLEET…` placeholder.

> **Note:** we are prompt-unlocking, so **do NOT put `zfs-passphrase` in
> `common.enc.yaml`.** The flake edit in §1.5 (`modules/sops.nix`) makes that
> secret conditional on `fleet.zfsAutoUnlock`, which node-B sets to `false`.

Create the encrypted shared secrets (rpc/admin/metrics only):

```bash
cp secrets/common.enc.yaml.example secrets/common.enc.yaml
$EDITOR secrets/common.enc.yaml          # paste rpc_secret/admin_token/metrics_token; DELETE the zfs-passphrase line
sops -e -i secrets/common.enc.yaml
```

Tailscale auth key (mint in the admin console: reusable, non-ephemeral,
`tag:garage`):

```bash
cp secrets/node.enc.yaml.example secrets/node-b.enc.yaml
$EDITOR secrets/node-b.enc.yaml   # paste tskey-auth-…
sops -e -i secrets/node-b.enc.yaml
```

### 1.2 Pre-generate node-B's SSH host key (the sops identity)

The node's age identity = `ssh-to-age` of its Ed25519 host key. Generate it now so
we can encrypt the secrets *to* it before install. Kept in a gitignored dir.

```bash
install -d -m700 node-b-extra/etc/ssh
ssh-keygen -t ed25519 -N "" -C node-b -f node-b-extra/etc/ssh/ssh_host_ed25519_key
ssh-to-age -i node-b-extra/etc/ssh/ssh_host_ed25519_key.pub
# -> prints age1…  (node-B's recipient)
```

### 1.3 Add node-B as a recipient + re-encrypt

In `.sops.yaml`: add the anchor and reference it under **both** creation rules
(`common` and the per-node rule):

```yaml
keys:
  - &fleet_workstation age1…           # from 1.1
  - &node_b           age1…            # from 1.2 (ssh-to-age output)

creation_rules:
  - path_regex: secrets/common\.enc\.ya?ml$
    key_groups:
      - age:
          - *fleet_workstation
          - *node_b
  - path_regex: secrets/node-b\.enc\.ya?ml$
    key_groups:
      - age:
          - *fleet_workstation
          - *node_b
```

Re-encrypt the two files to the new recipient set:

```bash
sops updatekeys secrets/common.enc.yaml
sops updatekeys secrets/node-b.enc.yaml
sops -d secrets/common.enc.yaml >/dev/null && echo "decrypt OK"
```

### 1.4 New files

**`hosts/disko-node-b.nix`** — both disks, two encrypted pools, prompt key.

```nix
# hosts/disko-node-b.nix — node-B (offsite-1), interactive install (doc 12).
# NVMe = ESP + UNENCRYPTED ext4 root + encrypted `npool` (meta + ssd data).
# HDD  = encrypted `dpool` (bulk data). keylocation="prompt": disko asks for the
# passphrase at format, and you re-enter it post-boot to unlock (never stored).
{ ... }:
{
  disko.devices = {
    disk = {
      # --- NVMe 500GB: ESP + ext4 root + npool ------------------------------
      nvme = {
        type = "disk";
        device = "/dev/nvme0n1";      # TODO operator: confirm with `lsblk`
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              type = "EF00";
              size = "512M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "60G";           # OS root; the rest of the NVMe → npool
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "npool";
              };
            };
          };
        };
      };

      # --- HDD 1TB: whole disk → dpool --------------------------------------
      hdd = {
        type = "disk";
        device = "/dev/sda";          # TODO operator: confirm with `lsblk`
        content = {
          type = "zfs";
          pool = "dpool";
        };
      };
    };

    zpool = {
      # NVMe: one encryptionroot (npool/garage) → meta + ssd data inherit it.
      npool = {
        type = "zpool";
        mode = "";
        rootFsOptions = {
          compression = "zstd";
          "com.sun:auto-snapshot" = "false";   # sanoid owns snapshots
          acltype = "posixacl";
          xattr = "sa";
        };
        options.ashift = "12";
        datasets = {
          "garage" = {
            type = "zfs_fs";
            options = {
              encryption = "aes-256-gcm";
              keyformat = "passphrase";
              keylocation = "prompt";          # typed at format + every unlock
              mountpoint = "none";             # container only
            };
          };
          "garage/meta" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/meta";
            options.recordsize = "16K";
          };
          "garage/data" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/data-ssd";
            options.recordsize = "1M";
          };
        };
      };

      # HDD: second encryptionroot (dpool/garage) → bulk data inherits it.
      dpool = {
        type = "zpool";
        mode = "";
        rootFsOptions = {
          compression = "zstd";
          "com.sun:auto-snapshot" = "false";
          acltype = "posixacl";
          xattr = "sa";
        };
        options.ashift = "12";
        datasets = {
          "garage" = {
            type = "zfs_fs";
            options = {
              encryption = "aes-256-gcm";
              keyformat = "passphrase";
              keylocation = "prompt";
              mountpoint = "none";
            };
          };
          "garage/data" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/data-hdd";
            options.recordsize = "1M";
          };
        };
      };
    };
  };
}
```

> Two encryptionroots ⇒ `zfs load-key -a` prompts **twice** (once per pool). Type
> the **same** passphrase both times to keep one passphrase to remember.

**`hosts/node-b-hardware.nix`** — AMD M715q. (Optional: regenerate on the box
with `nixos-generate-config --root /mnt` and diff — this hand-written minimal
module is correct for this hardware.)

```nix
# hosts/node-b-hardware.nix — Lenovo ThinkCentre M715q Tiny, AMD PRO A10-9700E.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
```

### 1.5 File edits (existing modules)

**`hosts/node-b.nix`** — replace the whole file:

```nix
# hosts/node-b.nix — OFFSITE-1 storage + Tailscale scraper-egress proxy.
# Installed INTERACTIVELY from a NixOS live USB (doc 12), NOT dd/nixos-anywhere.
{ ... }:
{
  imports = [
    ./disko-node-b.nix
    ./node-b-hardware.nix
    ../modules/zfs-sanoid.nix
  ];

  networking.hostName = "node-b";
  networking.hostId = "90b2c268";        # unique 8-hex ZFS hostId

  # Both data pools import at boot; their datasets stay LOCKED until you
  # `zfs load-key -a` post-boot over the tailnet (keylocation=prompt).
  boot.zfs.extraPools = [ "npool" "dpool" ];
  # Do NOT block boot waiting for a passphrase — unlock happens post-boot.
  boot.zfs.requestEncryptionCredentials = false;

  fleet = {
    role = "storage";
    zone = "offsite-1";
    proxyNode = true;
    zfsAutoUnlock = false;               # prompt-unlock; no passphrase on box

    # TODO operator: node-B's tailscale0 overlay IP — set AFTER first join (§7).
    tailscaleIp = "100.64.0.11";

    # TODO operator: LAN subnet this proxy advertises (scraper-egress role),
    # e.g. [ "192.168.1.0/24" ]. Leave [] until you wire the proxy route.
    advertiseRoutes = [ ];

    # Garage spans NVMe (ssd) + HDD. Capacities ≈ usable space, tune after
    # `zpool list`. sanoid snapshots BOTH data pools (the moat).
    dataDirs = [
      { path = "/srv/garage/data-ssd"; capacity = "400G"; }
      { path = "/srv/garage/data-hdd"; capacity = "900G"; }
    ];
    sanoidDatasets = [ "npool/garage" "dpool/garage" ];
  };

  sops.secrets."tailscale-authkey".sopsFile = ../secrets/node-b.enc.yaml;
}
```

**`modules/base.nix`** — (a) fill the two SSH key lists, (b) add one option.

```nix
  # users.users.ops.openssh.authorizedKeys.keys = [ ... ];
  users.users.ops.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA…YOURKEY operator@workstation"   # TODO operator: your pubkey
  ];
  # users.users.root.openssh.authorizedKeys.keys = [ ... ];
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA…YOURKEY operator@workstation"   # TODO operator: deploy key
  ];
```

Add to the `options.fleet` block (next to `tailscaleIp`/`zone`/`role`):

```nix
    zfsAutoUnlock = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "true = auto-unlock data pool from a sops passphrase at boot; false = prompt-unlock post-boot (offsite default).";
    };
```

**`modules/sops.nix`** — gate the passphrase on the option, not the role:

```nix
    # was: secrets."zfs-passphrase" = lib.mkIf (config.fleet.role == "storage") {
    secrets."zfs-passphrase" = lib.mkIf config.fleet.zfsAutoUnlock {
```

**`modules/garage.nix`** — multi `data_dir` + don't start before mount.

In the `let … in`, add after `dataDir`:

```nix
  dataPaths = if cfg.dataDirs != null then map (d: d.path) cfg.dataDirs else [ dataDir ];
```

Add an `options` block (sibling of `config`) at the top of the returned set:

```nix
  options.fleet.dataDirs = lib.mkOption {
    type = lib.types.nullOr (lib.types.listOf (lib.types.attrsOf lib.types.str));
    default = null;
    description = "Multi-disk Garage data_dir list [{path,capacity}]; null = single dataDir.";
  };
```

Change the data_dir setting and add the start condition:

```nix
        # was: data_dir = dataDir;
        data_dir = if cfg.dataDirs != null then cfg.dataDirs else dataDir;
```

```nix
    # near the tmpfiles.rules block — storage nodes must NOT start until the
    # encrypted datasets are unlocked + mounted (prompt-unlock), or Garage would
    # write into empty unmounted dirs.
    systemd.services.garage.unitConfig = lib.mkIf (!isGateway) {
      ConditionPathIsMountPoint = [ metaDir ] ++ dataPaths;
    };
```

**`modules/tailscale.nix`** — advertise the proxy route from the option.

Add to the `options.fleet` block (next to `proxyNode`):

```nix
  options.fleet.advertiseRoutes = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Subnet routes this proxy advertises, e.g. [\"192.168.1.0/24\"].";
  };
```

Extend `extraUpFlags`'s proxy branch:

```nix
        ++ lib.optionals isProxy [
          "--advertise-exit-node"
        ]
        ++ lib.optionals (isProxy && cfg.advertiseRoutes != [ ]) [
          "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}"
        ];
```

**`modules/zfs-sanoid.nix`** — datasets from the option (pools are now npool/dpool).

Add to the module (it currently has only `config`):

```nix
  options.fleet.sanoidDatasets = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "bpool/garage" ];
    description = "ZFS datasets sanoid snapshots (the moat).";
  };
```

Replace the hardcoded `datasets."bpool/garage"` block with:

```nix
      datasets = lib.genAttrs config.fleet.sanoidDatasets (_: {
        useTemplate = [ "garage" ];
        recursive = true;
      });
```

### 1.6 Lock + sanity-check the flake (on the workstation)

```bash
nix flake lock                     # no-op if flake.lock is already committed (it is)
nix flake check                    # deploy-rs schema + eval
nix build .#nixosConfigurations.node-b.config.system.build.toplevel --dry-run
```

If `nix flake check` / `--dry-run` pass, the config evaluates. Three things to
**verify on real nix** (can't be checked in this repo's dev env):
- `pkgs.garage_2` resolves on your pinned nixpkgs (else `garage_2_x` — fix in
  `modules/garage.nix`).
- `data_dir` renders as a TOML array-of-tables (`[[data_dir]]`); confirm in the
  built `garage.toml`.
- disko prompts for the passphrase at format with `keylocation = "prompt"`.

### 1.7 Stage the install payload

Copy these onto your **second USB stick** (or anywhere you can reach from the
box). Do **not** put the host *private* key in git.

```
garage-fleet/                      # the whole dir (incl. encrypted secrets/*.enc.yaml)
garage-fleet/node-b-extra/etc/ssh/ssh_host_ed25519_key       # the private key
garage-fleet/node-b-extra/etc/ssh/ssh_host_ed25519_key.pub
```

`node-b-extra/` is gitignored, so when you copy the **git working tree** it won't
be included — copy it explicitly. (The encrypted `secrets/*.enc.yaml` **are**
tracked and must be present in the flake source.)

---

## 2. Make the NixOS installer USB

On your workstation. Use the **minimal** ISO (x86_64).

```bash
# Download the current minimal ISO (or grab it from nixos.org/download).
nix build nixpkgs#nixos-installer.iso 2>/dev/null || \
  curl -L -o nixos-minimal.iso \
  https://channels.nixos.org/nixos-25.05/latest-nixos-minimal-x86_64-linux.iso

lsblk                              # IDENTIFY the USB stick device, e.g. /dev/sdX
sudo dd if=nixos-minimal.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

> ⚠️ `dd` is destructive. `of=` must be the **USB stick**, never your workstation
> disk. Double-check with `lsblk` (size + removable flag).

---

## 3. Boot node-B from the USB

1. Plug installer USB + (second USB with the payload) + monitor + keyboard + ethernet.
2. Power on, tap **F12** (Lenovo boot menu) → select the USB.
3. At the live shell, become root and confirm network + disks:

```bash
sudo -i
ping -c1 nixos.org                 # confirm DHCP/network
lsblk                              # CONFIRM nvme0n1 (500G) and sda (1T) — fix
                                   # device paths in disko-node-b.nix if different
```

> If the device names differ (e.g. HDD is `sdb`), edit `device =` in
> `hosts/disko-node-b.nix` on the payload before §5.

---

## 4. Get the flake onto the live system

Mount the second USB and copy the payload:

```bash
mkdir -p /mnt-usb && mount /dev/sdY1 /mnt-usb      # the PAYLOAD usb (lsblk to find)
cp -r /mnt-usb/garage-fleet /root/garage-fleet
ls /root/garage-fleet/node-b-extra/etc/ssh/        # host key present?
```

> **Alt (git clone, needs a PAT for a private repo):**
> `nix shell nixpkgs#git -c git clone -b feat/garage-backup-cluster https://<PAT>@github.com/<you>/<repo>.git /root/repo`
> then `cp -r /root/repo/garage-fleet /root/garage-fleet` and copy `node-b-extra/`
> from the USB separately (it's gitignored).

Enable flakes in the live env and lock if needed:

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"
cd /root/garage-fleet
[ -f flake.lock ] || nix flake lock
```

---

## 5. Partition + format with disko (prompts for the passphrase)

```bash
cd /root/garage-fleet
nix run .#disko -- \
  --mode destroy,format,mount \
  --flake .#node-b \
  --yes-wipe-all-disks
```

- disko **DESTROYS** `nvme0n1` and `sda`, creates ESP+root+npool+dpool.
- It will pause and print **`Enter passphrase:`** — once for `npool/garage`, once
  for `dpool/garage`. **Type the same passphrase both times.** This is the *only*
  copy of that passphrase — write it down offline now (two locations).

Verify the mount tree under `/mnt`:

```bash
lsblk
mount | grep /mnt
zfs list                           # npool/garage/{meta,data}, dpool/garage/data
ls -la /mnt/srv/garage/            # meta, data-ssd, data-hdd mountpoints
```

---

## 6. Inject the SSH host key + install

The pre-generated host key (matches the sops recipient from §1.2) must land in
the installed system **before** first activation, or sops can't decrypt.

```bash
install -d -m700 /mnt/etc/ssh
cp /mnt-usb/garage-fleet/node-b-extra/etc/ssh/ssh_host_ed25519_key      /mnt/etc/ssh/
cp /mnt-usb/garage-fleet/node-b-extra/etc/ssh/ssh_host_ed25519_key.pub  /mnt/etc/ssh/
chmod 600 /mnt/etc/ssh/ssh_host_ed25519_key
chmod 644 /mnt/etc/ssh/ssh_host_ed25519_key.pub
```

Install the flake (this builds + copies the closure + bootloader):

```bash
nixos-install --flake /root/garage-fleet#node-b --no-root-passwd
```

> `--no-root-passwd`: root login is key-only (base.nix). If you want a console
> root password instead, drop the flag and set one when prompted. The `ops` user
> + your SSH key (base.nix §1.5) is the normal admin path.

When it finishes:

```bash
umount -R /mnt && zpool export -a   # clean unmount (export both pools)
reboot
```

Pull the installer USB during reboot.

---

## 7. First boot: tailnet join, then fix the overlay IP

The box boots on its own (root unencrypted). sops decrypts (host key present) →
tailscale auto-joins with the authkey. Data pools are imported but **locked**.

At the console (or `ssh ops@<lan-ip>`):

```bash
tailscale status                   # confirm joined; note node-B's 100.x.y.z IP
zfs list                           # pools present; garage/* show no mountpoint yet
systemctl status garage            # INACTIVE (ConditionPathIsMountPoint) — expected
```

The guessed `tailscaleIp` in `node-b.nix` is almost certainly wrong. Garage binds
that exact IP, so set the **real** one and rebuild. Easiest while bootstrapping:
copy the flake onto the booted node and rebuild locally.

```bash
# get the flake onto the installed system (USB copy, or scp from workstation)
sudo cp -r /mnt-usb/garage-fleet /root/garage-fleet      # if USB still attached
# edit hosts/node-b.nix: set fleet.tailscaleIp = "100.x.y.z" (from tailscale status)
# (optional) set fleet.advertiseRoutes = [ "192.168.x.0/24" ] for the proxy role
sudo nixos-rebuild switch --flake /root/garage-fleet#node-b
```

> Going forward, the intended ops path is `deploy .#node-b` from the workstation
> over the tailnet (deploy-rs, magic-rollback). The local rebuild above is just
> the first-boot bootstrap before a deploy-rs baseline exists.

Commit the `tailscaleIp`/`advertiseRoutes` change on the workstation branch too,
so the source of truth matches the box.

---

## 8. Unlock the data pools + bring Garage up

```bash
sudo zfs load-key -a               # prompts once per pool — same passphrase
sudo zfs mount -a
mount | grep /srv/garage           # meta, data-ssd, data-hdd now mounted
sudo systemctl start garage        # Condition now satisfied
systemctl status garage            # active (running)
```

Configure the single-node layout (Phase 1 bring-up; add peers later per doc 10):

```bash
export GARAGE="sudo garage"        # uses /etc/garage.toml + admin token
$GARAGE status                     # shows this node's ID, HEALTHY
NODE_ID=$($GARAGE node id -q | cut -d@ -f1)
$GARAGE layout assign "$NODE_ID" -z offsite-1 -c 1.3T
$GARAGE layout apply --version 1
$GARAGE status                     # node now has a role + capacity
```

Smoke test S3 over the tailnet:

```bash
$GARAGE bucket create smoke
$GARAGE key create smoke-key
# -> note the Access Key ID + Secret; then from any tag:garage device:
#   aws --endpoint-url http://100.x.y.z:3900 --region garage s3 ls
$GARAGE bucket info smoke
```

---

## 9. Verification gates

| Gate | Command | Expect |
|---|---|---|
| Boots unattended | power-cycle, no console input | reaches login, tailscale up |
| Pools locked at boot | `zfs get keystatus npool/garage dpool/garage` | `unavailable` until load-key |
| Garage waits for unlock | `systemctl status garage` pre-unlock | inactive (condition) |
| Listeners tailnet-only | `ss -tlnp | grep -E '3900|3901|3903'` | bound to `100.x.y.z`, never `0.0.0.0` |
| sops decrypts | `ls /run/secrets/` | rpc_secret, admin_token, metrics_token, tailscale-authkey |
| **No `zfs-passphrase` secret** | `ls /run/secrets/` | absent (prompt-unlock) |
| **Moat invariant** | `zfs allow npool/garage; zfs allow dpool/garage` | `garage` user appears **nowhere** |
| Both disks in Garage | `garage stats` / `df -h /srv/garage/*` | ssd + hdd data dirs both used |
| Sanoid running | `systemctl status sanoid.timer` | active; `zfs list -t snapshot` grows |

### Even-simpler opt-outs (if you don't want the per-reboot unlock)

- **(a) auto-unlock via sops** (weaker offsite theft story): set
  `fleet.zfsAutoUnlock = true` in `node-b.nix`, put `zfs-passphrase` in
  `common.enc.yaml` (re-encrypt), and change both pools'
  `keylocation = "prompt"` → `keylocation = "file://${config.sops.secrets."zfs-passphrase".path}"`
  plus a boot `zfs load-key` unit ordered after sops-nix. Box then unlocks itself.
- **(b) no data encryption**: drop the three `encryption`/`keyformat`/`keylocation`
  lines (and `mountpoint = "none"`) from both `garage` datasets in
  `disko-node-b.nix`. Simplest, zero theft protection at rest.

---

## 10. Routine ops (after any reboot)

The box comes back on its own, but Garage stays down until you unlock:

```bash
ssh ops@node-b.<tailnet>.ts.net
sudo zfs load-key -a && sudo zfs mount -a
sudo systemctl start garage
```

(Or script it as a tiny `systemd` `Type=oneshot` you trigger over SSH — but never
store the passphrase on the box; that defeats prompt-unlock.)

---

## 11. Relation to other docs

- **Supersedes doc 11** (`dd`/image-flash). Keep doc 11 only as the
  flash-from-another-machine alternative; this USB method is the chosen path.
- Builds on **doc 09** (design/ADRs) and **doc 10** (phased plan). Layout,
  peering, gateway node-D, restic/Kopia clients, sanoid retention = doc 10.
- node-A/-C/-D still install per their own host files; only node-B uses this
  two-disk interactive layout.
```
