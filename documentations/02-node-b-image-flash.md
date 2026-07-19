# node-B — build by flashing a prebuilt NixOS image to NVMe

Step-by-step runbook to bring up the **first Garage backup-fleet node** by
building a NixOS disk image on your workstation, `dd`-ing it onto the NVMe, and
plugging that NVMe into the box — instead of the `nixos-anywhere`-over-SSH flow
in `documentations/01` Phase 1/2.

Read `documentations/00` (the *why*) and `documentations/01` (the phased plan
this specialises) first. This guide is the concrete command-by-command build for
**node-B specifically**, with every file to create/modify shown inline at the
step it is needed. All paths are in the `garage-fleet/` repo unless tagged
`[k8s]`.

---

## What you are building

| Item | Value |
|---|---|
| Node | **node-B**, zone `offsite-1`, role storage **+ proxy** (`fleet.proxyNode=true`) |
| Box | Lenovo ThinkCentre M715q Tiny (`10VGS05N00`), AMD PRO A10-9700E, x86_64 UEFI |
| NVMe `/dev/nvme0n1` (500 GB) | `p1` ESP + `p2` **unencrypted** ext4 root + `p3` zpool `npool` |
| HDD `/dev/sda` (1 TB) | zpool `dpool` (bulk object data), formatted **post-boot** |
| Encryption | aes-256-gcm, `keylocation=prompt` — **no key on the box** |
| Capacity | Garage multi `data_dir`: ssd ~400 GB + hdd ~950 GB ≈ 1.35 TB (gated `fleet.hddData`) |
| Build | disko `diskoImages` → `dd` to NVMe (greenfield, box is blank) |
| Deploy after install | `deploy-rs` (magic rollback) |

### The unlock model (read this once)

The OS **root is unencrypted**. Only the Garage *data* datasets are encrypted.
So the box boots fully on its own — `sshd` and `tailscale` come up — and the
encrypted pool stays **locked** until you unlock it **after boot, over the
tailnet**:

```bash
ssh ops@node-b.<tailnet>.ts.net
sudo zfs load-key -a && sudo zfs mount -a && sudo systemctl start garage
```

A stolen box keeps the backup data encrypted-at-rest (the passphrase is never
written to the box). Cost: one unlock command per reboot. No initrd-SSH / Tang
needed (those only matter when *root* is encrypted). Garage is gated with
`ConditionPathIsMountPoint` so it stays idle — not crash-looping — while locked.

> The ZFS passphrase is **break-glass**: you choose it at first boot, it lives
> only in your head / password manager, in **two** offline places. Lose it and
> the data is unrecoverable.

---

## 0. Operator values to fill in

Search the files below for `TODO operator` and `<...>`. Decide these first:

| Placeholder | Where | Note |
|---|---|---|
| `<tailnet>` MagicDNS name | `flake.nix` deploy, this guide's ssh commands | e.g. `tail1234.ts.net` |
| node-B overlay IP `100.x.x.x` | `hosts/node-b.nix` `fleet.tailscaleIp` | the `100.x` Tailscale assigns node-B; Garage binds to it |
| proxy `--advertise-routes` subnet | `hosts/node-b.nix` `fleet.advertiseRoutes` | the LAN subnet node-B routes for the scraper-egress role; or `[]` for exit-node only |
| operator SSH pubkey(s) | `modules/base.nix` `ops` + `root` | break-glass + deploy key |
| `hostId` | `hosts/node-b.nix` | already generated below: `90b2c268` |

---

## 1. Secrets — separate trust domain (doc 01 Phase 0)

Do this on your **workstation** with `nix`, `sops`, `age`, `ssh-to-age` available.

### 1.1 Pre-generate node-B's SSH host key

Its key derives node-B's age identity, so sops can decrypt at first boot. We make
it now and inject it into the image later (Step 3.2).

```bash
cd garage-fleet
mkdir -p node-b-extra/etc/ssh
ssh-keygen -t ed25519 -N "" -C "node-b" \
  -f node-b-extra/etc/ssh/ssh_host_ed25519_key
chmod 600 node-b-extra/etc/ssh/ssh_host_ed25519_key

# node-B's age recipient (paste into .sops.yaml next):
ssh-to-age < node-b-extra/etc/ssh/ssh_host_ed25519_key.pub
```

> `node-b-extra/` is gitignored (`node-*-extra/` in `.gitignore`) — the private
> host key never gets committed.

### 1.2 Fleet age key + shared secrets

```bash
./secrets/gen-secrets.sh        # mints fleet age key, prints recipient + rpc/admin/metrics
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/garage-fleet.txt"
```

Edit `garage-fleet/.sops.yaml`: replace the `age1FLEET…` placeholder with the
fleet recipient, and **uncomment + fill `&node_b`** with node-B's recipient from
Step 1.1, in both `creation_rules`:

```yaml
keys:
  - &fleet_workstation age1<paste fleet recipient from gen-secrets.sh>
  - &node_b           age1<paste node-B recipient from ssh-to-age>

creation_rules:
  - path_regex: secrets/common\.sops\.ya?ml$
    key_groups:
      - age:
          - *fleet_workstation
          - *node_b
  - path_regex: secrets/.*-tailscale\.sops\.ya?ml$
    key_groups:
      - age:
          - *fleet_workstation
          - *node_b
```

### 1.3 Encrypt the shared secrets — **without** `zfs-passphrase`

node-B uses **prompt-unlock**, so its ZFS key must NOT live in sops. Copy the
template, fill rpc/admin/metrics, **delete the `zfs-passphrase` line**, encrypt:

```bash
cp secrets/common.sops.yaml.example secrets/common.sops.yaml
# edit: paste rpc_secret / admin_token / metrics_token (openssl rand -hex 32 each)
#       DELETE the zfs-passphrase line entirely
sops -e -i secrets/common.sops.yaml
```

### 1.4 Tailscale auth key for node-B

Mint a **reusable, non-ephemeral, tag:garage** key in the Tailscale admin
console, then:

```bash
cp secrets/node-tailscale.sops.yaml.example secrets/node-b-tailscale.sops.yaml
# edit: paste the tskey-auth-… value
sops -e -i secrets/node-b-tailscale.sops.yaml
```

### 1.5 Tailscale ACL (admin console, deny-by-default — doc 00 §3)

- `tag:garage ↔ tag:garage` on `tcp:3900,3901,3903`
- `tag:k8s → tag:garage` on **`tcp:3900` only** (never 3901/3903)
- approve node-B's advertised route / exit-node (Step 0)

**Gate:** `sops -d secrets/common.sops.yaml >/dev/null && echo OK`

---

## 2. The IaC — files to create / modify

All under `garage-fleet/`. New files first, then edits to existing modules.

### 2.1 NEW — `hosts/disko-node-b.nix` (the flashed NVMe)

Single NVMe: ESP + ext4 root + an **empty** encrypted-capable pool `npool`. The
encrypted datasets are NOT declared here — `diskoImages` builds non-interactively
and cannot prompt for the passphrase, so we create them by hand at first boot
(Step 4.2).

```nix
# hosts/disko-node-b.nix — single-NVMe layout for node-B, baked into the flashed
# image (documentations/02). ESP + UNENCRYPTED ext4 root + pool `npool`.
#
# Root is intentionally unencrypted so the box boots to multi-user (sshd +
# tailscale up) on its own; only the Garage DATA datasets on npool are encrypted
# and are unlocked POST-BOOT over the tailnet (doc 02 "unlock model"). The
# encrypted datasets npool/garage{,/meta,/data-ssd} are created by hand at first
# boot with keylocation=prompt — NOT declared here, because diskoImages builds in
# a non-interactive VM and cannot prompt.
{ lib, ... }:
{
  disko.devices = {
    disk.nvme = {
      type = "disk";
      device = lib.mkDefault "/dev/nvme0n1";
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
            size = "30G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
          # Rest of the NVMe → the ZFS pool. After flashing onto the real 500 GB
          # disk, grow this partition + `zpool online -e` to fill it (Step 3.4).
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

    zpool.npool = {
      type = "zpool";
      mode = ""; # single vdev
      rootFsOptions = {
        compression = "zstd";
        "com.sun:auto-snapshot" = "false"; # sanoid owns snapshots
        acltype = "posixacl";
        xattr = "sa";
        autoexpand = "on"; # let the pool grow when p3 is grown post-flash
      };
      options.ashift = "12";
      # NO datasets here — created at first boot (Step 4.2), encrypted, prompt.
      datasets = { };
    };
  };
}
```

### 2.2 NEW — `hosts/disko-node-b-hdd.nix` (the post-boot HDD)

Standalone disko config for the 1 TB HDD. Run **on the booted node** (Step 4.4)
— pool only, encrypted dataset created by hand alongside the NVMe ones.

```nix
# hosts/disko-node-b-hdd.nix — the 1 TB SATA HDD on node-B, formatted POST-BOOT
# (documentations/02 Step 4.4), NOT part of the flashed image. Exposed as a
# standalone diskoConfigurations.node-b-hdd in flake.nix and applied with
#   disko --mode destroy,format,mount --flake .#node-b-hdd
# Pool only; the encrypted dpool/garage/data-hdd dataset is created by hand at
# first boot with keylocation=prompt (same step as the npool datasets).
{ lib, ... }:
{
  disko.devices = {
    disk.hdd = {
      type = "disk";
      device = lib.mkDefault "/dev/sda";
      content = {
        type = "zfs";
        pool = "dpool";
      };
    };
    zpool.dpool = {
      type = "zpool";
      mode = "";
      rootFsOptions = {
        compression = "zstd";
        "com.sun:auto-snapshot" = "false";
        acltype = "posixacl";
        xattr = "sa";
      };
      options.ashift = "12";
      datasets = { }; # created by hand at first boot (Step 4.2)
    };
  };
}
```

### 2.3 NEW — `hosts/node-b-hardware.nix`

Generic-but-correct hardware config for the M715q (AMD, NVMe + SATA). Refine
after first boot with `nixos-generate-config` if you like.

```nix
# hosts/node-b-hardware.nix — hardware config for the Lenovo M715q Tiny
# (AMD A10-9700E). Minimal generic set good enough to boot the flashed image;
# regenerate with `nixos-generate-config --show-hardware-config` on the booted
# node to refine if needed (documentations/02).
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # NVMe for root, AHCI/sd_mod for the SATA HDD, usb + xhci for input/recovery.
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "sd_mod"
    "usbhid"
    "usb_storage"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # ZFS lives in the running system (data pool imported in stage-2), not initrd.
  boot.supportedFilesystems = [ "zfs" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;
  hardware.enableRedistributableFirmware = lib.mkDefault true;
}
```

### 2.4 MODIFY — `hosts/node-b.nix` (replace the whole file)

Swaps the 2-disk `disko-storage.nix` import for the single-NVMe layout, adds the
hardware import, sets the proxy/zone/IP/hostId, switches the bootloader to
**GRUB removable** (so a flashed image boots with no NVRAM entry), imports the
ZFS pools, and makes Garage wait for the post-boot unlock.

```nix
# hosts/node-b.nix — OFFSITE-1 storage + Tailscale scraper-egress proxy, built by
# flashing a prebuilt image to NVMe (documentations/02). Single NVMe (boot + meta
# + ssd data) + a 1 TB HDD added post-boot for bulk data. Prompt-unlock ZFS:
# root is unencrypted, the Garage data pool is unlocked post-boot over the tailnet.
{ lib, ... }:
{
  imports = [
    ./disko-node-b.nix
    ./node-b-hardware.nix
    ../modules/zfs-sanoid.nix
  ];

  networking.hostName = "node-b";
  networking.hostId = "90b2c268"; # unique per machine; stable

  fleet = {
    role = "storage";
    zone = "offsite-1";
    proxyNode = true; # exit-node + subnet route (scraper-egress role)
    zfsAutoUnlock = false; # prompt-unlock — no key on the box (offsite)
    hddData = false; # flip to true AFTER the HDD is formatted (Step 4.5)

    # TODO operator: node-B's tailscale0 overlay IP (the 100.x Tailscale assigns).
    tailscaleIp = "100.64.0.11";
    # TODO operator: LAN subnet(s) node-B routes for scraper egress, e.g.
    # [ "192.168.1.0/24" ]. Leave [] for exit-node only. Approve in the ACL.
    advertiseRoutes = [ ];
    # sanoid snapshots the encrypted Garage datasets (the moat). dpool is added
    # once hddData flips true.
    sanoidDatasets = [ "npool/garage" ] ++ lib.optional false "dpool/garage";
  };

  # Import the ZFS pools at boot. Datasets stay LOCKED until the post-boot
  # `zfs load-key` (doc 02 unlock model). dpool added after the HDD exists.
  boot.zfs.extraPools = [ "npool" ];

  # --- bootloader: GRUB removable for a FLASHED image ----------------------
  # systemd-boot (base.nix default) relies on an EFI NVRAM boot entry the image
  # build can't write. GRUB efiInstallAsRemovable writes /EFI/BOOT/BOOTX64.EFI so
  # the firmware boots it with no NVRAM entry — the right choice for `dd`'d media.
  boot.loader.systemd-boot.enable = false;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    devices = [ "nodev" ];
    configurationLimit = 10;
  };

  sops.secrets."tailscale-authkey".sopsFile = ../secrets/node-b-tailscale.sops.yaml;

  # Garage must not start until the encrypted data pool is unlocked + mounted
  # (set in modules/garage.nix via ConditionPathIsMountPoint). Until then it sits
  # inactive — no crash loop. Unlock: see doc 02 "unlock model".
}
```

> When you later format the HDD and set `hddData = true` (Step 4.5), also change
> the two `false` markers above: `lib.optional true "dpool/garage"` and
> `boot.zfs.extraPools = [ "npool" "dpool" ]`. (Kept explicit here so the file is
> readable; you may instead wire them to `config.fleet.hddData`.)

### 2.5 MODIFY — `modules/base.nix` (add fleet options + fill SSH keys)

**(a)** Add the new `fleet.*` options. In the `options.fleet = { … }` block,
alongside the existing `tailscaleIp` / `zone` / `role`, add:

```nix
    hddData = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Include the post-boot HDD pool in Garage data_dir + sanoid (doc 02).";
    };

    zfsAutoUnlock = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "true = sops-baked passphrase auto-unlock; false = keylocation=prompt (offsite, doc 02).";
    };

    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Subnet routes this proxy node advertises (tailscale --advertise-routes).";
    };

    sanoidDatasets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "bpool/garage" ];
      description = "ZFS datasets sanoid snapshots (the moat). Per-host (doc 02 uses npool/dpool).";
    };
```

**(b)** Fill the operator SSH keys (replace the empty `keys = [ … ]`):

```nix
    users.users.ops.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA...your-key... operator@workstation"
    ];
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA...your-deploy-key... deploy@workstation"
    ];
```

### 2.6 MODIFY — `modules/garage.nix` (replace the whole file)

Changes vs the scaffold: storage `metadata_dir = /srv/garage/meta`; `data_dir`
becomes `data-ssd` (single) or a multi-dir list with capacities once `hddData`;
Garage waits for the unlocked mount via `ConditionPathIsMountPoint`.

```nix
# modules/garage.nix — the Garage object-store service (doc 00 §5, doc 02).
# Every listener binds the node's tailscale0 overlay IP only, never 0.0.0.0.
#
# Storage nodes (A/B/C): metadata on /srv/garage/meta, object data on
# /srv/garage/data-ssd (+ /srv/garage/data-hdd once fleet.hddData). Those mounts
# are ENCRYPTED ZFS datasets unlocked post-boot (doc 02), so garage is gated with
# ConditionPathIsMountPoint and stays idle until you unlock + start it.
# Gateway (D): capacity 0, tiny local dirs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet;
  tsIp = cfg.tailscaleIp;
  isGateway = cfg.role == "gateway";

  metaDir = "/srv/garage/meta";
  ssdData = "/srv/garage/data-ssd";
  hddDataDir = "/srv/garage/data-hdd";

  # gateway: single local dir. storage: data-ssd only, or multi (ssd+hdd) with
  # per-path capacities once the HDD is in. Multi-dir renders TOML [[data_dir]].
  # TODO operator: tune the capacity strings to the real usable sizes.
  dataDir =
    if isGateway then
      "/srv/garage/data"
    else if cfg.hddData then
      [
        { path = ssdData; capacity = "400G"; }
        { path = hddDataDir; capacity = "950G"; }
      ]
    else
      ssdData;
in
{
  config = {
    services.garage = {
      enable = true;
      # ⚠️ Pin Garage v2.3.0 — confirm the attr resolves on your pinned nixpkgs.
      package = pkgs.garage_2;
      settings = {
        metadata_dir = metaDir;
        data_dir = dataDir;
        db_engine = "lmdb";

        replication_factor = 3; # IDENTICAL on every node
        consistency_mode = "consistent";
        metadata_auto_snapshot_interval = "6h";

        # IPv4 overlay IP → NO brackets (brackets are for IPv6 literals only).
        rpc_bind_addr = "${tsIp}:3901";
        rpc_public_addr = "${tsIp}:3901";
        rpc_secret_file = config.sops.secrets."rpc_secret".path;

        # Single node for the node-B bring-up; add peers in doc 01 Phase 2.
        bootstrap_peers = [ ];

        s3_api = {
          api_bind_addr = "${tsIp}:3900";
          s3_region = "garage";
        };

        admin = {
          api_bind_addr = "${tsIp}:3903";
          admin_token_file = config.sops.secrets."admin_token".path;
          metrics_token_file = config.sops.secrets."metrics_token".path;
        };
      };
    };

    # Gateway needs its local dirs to exist; storage gets them from ZFS mounts.
    systemd.tmpfiles.rules = lib.mkIf isGateway [
      "d ${metaDir} 0700 garage garage -"
      "d /srv/garage/data 0700 garage garage -"
    ];

    # Storage: don't start garage until the encrypted data pool is unlocked +
    # mounted (doc 02). Stays inactive — not crash-looping — while locked.
    systemd.services.garage = lib.mkIf (!isGateway) {
      unitConfig.ConditionPathIsMountPoint = [ metaDir ssdData ];
      after = [ "zfs-mount.service" ];
    };
  };
}
```

### 2.7 MODIFY — `modules/sops.nix` (gate the ZFS passphrase)

Prompt-unlock means node-B must NOT carry a sops ZFS key. Change the
`zfs-passphrase` secret's guard from `role == "storage"` to the new
`fleet.zfsAutoUnlock` flag (node-B leaves it `false`):

```nix
    # was: lib.mkIf (config.fleet.role == "storage") { … }
    secrets."zfs-passphrase" = lib.mkIf config.fleet.zfsAutoUnlock {
      sopsFile = ../secrets/common.sops.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
    };
```

> With `zfsAutoUnlock = false`, sops-nix never looks for `zfs-passphrase` — which
> is why Step 1.3 deletes it from `common.sops.yaml`.

### 2.8 MODIFY — `modules/tailscale.nix` (wire advertise-routes)

In the `extraUpFlags` `lib.optionals isProxy [ … ]` list, replace the
`--advertise-routes` TODO comment with a real flag driven by the option:

```nix
        ++ lib.optionals isProxy [
          "--advertise-exit-node"
        ]
        ++ lib.optional (cfg.advertiseRoutes != [ ]) (
          "--advertise-routes=" + lib.concatStringsSep "," cfg.advertiseRoutes
        );
```

### 2.9 MODIFY — `modules/zfs-sanoid.nix` (snapshot the per-host datasets)

Replace the hardcoded `datasets."bpool/garage"` block with one driven by
`fleet.sanoidDatasets` so node-B snapshots `npool/garage` (+ `dpool/garage`):

```nix
      datasets = lib.genAttrs config.fleet.sanoidDatasets (_: {
        useTemplate = [ "garage" ];
        recursive = true;
      });
```

### 2.10 MODIFY — `flake.nix` (expose the HDD disko config)

In the `outputs` attrset (next to `nixosConfigurations`), add:

```nix
      # Standalone disko config for node-B's post-boot HDD (doc 02 Step 4.4):
      #   disko --mode destroy,format,mount --flake .#node-b-hdd
      diskoConfigurations.node-b-hdd = import ./hosts/disko-node-b-hdd.nix;
```

### 2.11 Lock + check

```bash
cd garage-fleet
nix flake lock          # first time only; commit flake.lock
nix flake check         # evaluates configs + deploy-rs schema

# Sanity: confirm multi-dir would render as [[data_dir]] (after hddData flips):
nix eval --raw .#nixosConfigurations.node-b.config.services.garage.configFile 2>/dev/null \
  || echo "inspect garage.toml after first deploy instead"
```

**Gate:** `nix flake check` passes.

---

## 3. Build the image, inject the host key, flash the NVMe

### 3.1 Build the NVMe image

```bash
cd garage-fleet
nix build .#nixosConfigurations.node-b.config.system.build.diskoImages
ls -lh result/                # expect a raw image, e.g. result/main.raw (NVMe)
```

> `diskoImages` builds one image per declared disk. node-B declares only the
> NVMe, so you get one image. (The HDD is handled post-boot, Step 4.4.)

### 3.2 Inject node-B's SSH host key into the image

The private host key (node-B's age identity) must NOT go through the Nix store.
Copy it into the built image by loop-mounting the root partition:

```bash
IMG=result/main.raw                 # adjust to the actual filename in result/
cp --reflink=auto "$IMG" node-b.raw # work on a writable copy
LOOP=$(sudo losetup --show -Pf node-b.raw)   # e.g. /dev/loop0 -> loop0p1/p2/p3
sudo mkdir -p /mnt/nb
sudo mount "${LOOP}p2" /mnt/nb       # p2 = ext4 root
sudo install -d -m700 /mnt/nb/etc/ssh
sudo install -m600 node-b-extra/etc/ssh/ssh_host_ed25519_key      /mnt/nb/etc/ssh/
sudo install -m644 node-b-extra/etc/ssh/ssh_host_ed25519_key.pub  /mnt/nb/etc/ssh/
sync
sudo umount /mnt/nb
sudo losetup -d "$LOOP"
```

### 3.3 Flash the NVMe

> ⚠️ DESTRUCTIVE. `dd` to the wrong disk wipes it. Identify the NVMe first.

```bash
lsblk -dno NAME,SIZE,MODEL          # find the 500 GB NVMe, e.g. nvme0n1
DEST=/dev/nvme0n1                   # <-- SET to the verified NVMe device
sudo dd if=node-b.raw of="$DEST" bs=64M status=progress conv=fsync
sync
```

> If the NVMe is the workstation's own boot disk, do the flash from a different
> machine or a USB enclosure — never flash the disk you booted from.

### 3.4 Grow the pool to fill the 500 GB disk

The image is built smaller than 500 GB; expand `p3` + the pool after flashing.
Easiest done on the **booted node** (after Step 4.1), or now via the loop device:

```bash
# on the booted node-B (recommended), as root:
growpart /dev/nvme0n1 3            # grow partition 3 to fill the disk
zpool online -e npool nvme0n1p3    # autoexpand=on takes the new space
zpool list npool                   # SIZE now ~ full NVMe
```

**Gate:** `sudo sgdisk -p /dev/nvme0n1` (or `lsblk`) shows `p1`/`p2`/`p3`.

---

## 4. Boot + post-install

Install the NVMe in node-B, connect it to the network, power on.

### 4.1 Confirm it booted and joined the tailnet

The box boots on its own (root is unencrypted). `tailscale` comes up with the
baked auth key and tags `tag:garage`. Garage is **idle** (data pool locked).

```bash
# from the workstation, over the tailnet:
tailscale status | grep node-b
ssh ops@node-b.<tailnet>.ts.net
systemctl status garage          # expect: inactive (ConditionPathIsMountPoint not met)
zpool list                       # npool present, imported
```

### 4.2 Create the encrypted datasets (once) — you choose the passphrase

On node-B, as root. The `zfs create` of the encryption root prompts for a NEW
passphrase — this is your break-glass key. Garage runs as user `garage`, so
hand it the mountpoints.

```bash
sudo zfs create -o encryption=aes-256-gcm -o keyformat=passphrase \
  -o keylocation=prompt -o mountpoint=none npool/garage
# ^ prompts: "Enter new passphrase" — pick a strong one, store it offline x2

sudo zfs create -o recordsize=16K -o mountpoint=/srv/garage/meta     npool/garage/meta
sudo zfs create -o recordsize=1M  -o mountpoint=/srv/garage/data-ssd npool/garage/data-ssd

sudo chown -R garage:garage /srv/garage
```

> Confirm the moat invariant immediately: `zfs allow npool/garage` must show the
> `garage` user NOWHERE (doc 00 §7). Never `zfs allow garage … destroy/rollback`.

### 4.3 First deploy-rs baseline (arms magic rollback)

Configure `~/.ssh/config` so `node-b.<tailnet>.ts.net` uses your deploy key, then:

```bash
# from the workstation, garage-fleet root:
nix run github:serokell/deploy-rs -- .#node-b
```

> Edit `flake.nix`'s `deploy.nodes.node-b.hostname` to the real
> `node-b.<tailnet>.ts.net` first. This first push is the magic-rollback baseline
> — have console access available just in case.

### 4.4 Format the HDD

```bash
# from the workstation:
ssh root@node-b.<tailnet>.ts.net \
  'nix run github:nix-community/disko -- --mode destroy,format,mount --flake .#node-b-hdd'
```

> Older disko uses `--mode disko` instead of `--mode destroy,format,mount`. This
> creates the empty `dpool`. Then create its encrypted dataset on the node:

```bash
ssh root@node-b.<tailnet>.ts.net
sudo zfs create -o encryption=aes-256-gcm -o keyformat=passphrase \
  -o keylocation=prompt -o mountpoint=none dpool/garage
# ^ use the SAME passphrase as npool so one `zfs load-key -a` unlocks both
sudo zfs create -o recordsize=1M -o mountpoint=/srv/garage/data-hdd dpool/garage/data-hdd
sudo chown -R garage:garage /srv/garage/data-hdd
```

### 4.5 Turn on multi-disk data + import dpool, redeploy

In `hosts/node-b.nix` set:

```nix
    hddData = true;
    sanoidDatasets = [ "npool/garage" "dpool/garage" ];
```
```nix
  boot.zfs.extraPools = [ "npool" "dpool" ];
```

Then redeploy:

```bash
nix run github:serokell/deploy-rs -- .#node-b
```

Garage's `data_dir` now spans `data-ssd` + `data-hdd`; sanoid snapshots both
pools.

### 4.6 Unlock + start Garage

```bash
ssh ops@node-b.<tailnet>.ts.net
sudo zfs load-key -a            # prompts once; unlocks npool/garage + dpool/garage
sudo zfs mount -a
sudo systemctl start garage
systemctl status garage         # active
```

### 4.7 Garage layout (single node for now)

```bash
# on node-B (admin token is in /run/secrets; the garage CLI reads the local node):
sudo garage status                                   # note the node id
sudo garage layout assign <node-id> -z offsite-1 -c 1.3T
sudo garage layout show                              # review STAGED
sudo garage layout apply --version 1                 # exactly prev+1, ONCE
```

### 4.8 Smoke test S3

```bash
sudo garage key create smoke
sudo garage bucket create smoke-bkt
sudo garage bucket allow --read --write smoke-bkt --key smoke
# from anywhere on the tailnet (use the key id/secret printed above):
aws --endpoint http://<node-b-overlay-ip>:3900 --region garage \
  s3 cp /etc/hostname s3://smoke-bkt/hostname
aws --endpoint http://<node-b-overlay-ip>:3900 --region garage \
  s3 ls s3://smoke-bkt/
# cleanup:
sudo garage bucket delete --yes smoke-bkt
sudo garage key delete --yes smoke
```

---

## 5. Verification gates

- [ ] **Boot/unlock:** reboot node-B → it comes back, `sshd` + `tailscale` up,
      `garage` inactive; `sudo zfs load-key -a && zfs mount -a && systemctl start garage`
      brings it up. Stolen-box property: before unlock, `/srv/garage/*` is empty.
- [ ] **Encryption:** `zfs get encryption,keystatus npool/garage dpool/garage`
      → `aes-256-gcm`, `available` only after load-key.
- [ ] **Moat:** `zfs allow npool/garage` and `zfs allow dpool/garage` → the
      `garage` user appears NOWHERE.
- [ ] **Network isolation:** `ss -tlnp | grep -E '390[013]'` → bound to the
      overlay IP only, NOT `0.0.0.0` / the physical NIC.
- [ ] **Metrics:** `curl -H "Authorization: Bearer <metrics_token>" http://<overlay-ip>:3903/metrics`
      returns Prometheus text; an un-tokened request is refused.
- [ ] **Layout:** `garage layout show` → version 1, zone `offsite-1`, ~1.3 TB.
- [ ] **Capacity:** after Step 4.5, `garage stats` / `df` show both `data-ssd`
      and `data-hdd` in use; the rendered `garage.toml` uses `[[data_dir]]`.
- [ ] **Proxy:** node-B's advertised route / exit-node is approved in the ACL and
      the in-cluster scraper egress still works.
- [ ] **Snapshots:** after an hour, `zfs list -t snapshot npool/garage` shows the
      sanoid ladder accumulating.

---

## 6. Routine ops

- **Every reboot (manual unlock):** `ssh ops@node-b… ; sudo zfs load-key -a && sudo zfs mount -a && sudo systemctl start garage`.
- **Config change:** edit the nix, `deploy-rs .#node-b` (magic rollback auto-reverts a bad push).
- **Passphrase:** never stored on the box; keep two offline copies. To change it: `zfs change-key npool/garage` (and `dpool/garage`).
- **Adding node-A / node-C / node-D + the data-plane backup jobs:** continue with `documentations/01` Phases 2–8.

---

## 7. Why this differs from doc 01 Phase 1/2 (at a glance)

| doc 01 (nixos-anywhere) | doc 02 (this guide, node-B) |
|---|---|
| Boots a rescue image, installs over SSH | Flash a prebuilt image to NVMe, plug in |
| 2-disk single pool, auto-unlock (`file://` key) | NVMe (boot+meta+ssd) + HDD (bulk); **prompt-unlock** |
| ZFS key seeded via `--disk-encryption-keys`, persisted in sops | ZFS key never on the box; unlocked post-boot over tailnet |
| `--extra-files` seeds the SSH host key | host key injected into the image via loop-mount (Step 3.2) |
| systemd-boot | GRUB removable (`/EFI/BOOT/BOOTX64.EFI`) for `dd`'d media |

See `documentations/00` for the design rationale and `documentations/01` for the
full multi-node + data-plane plan.
```
