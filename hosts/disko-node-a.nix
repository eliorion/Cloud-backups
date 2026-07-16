# hosts/disko-node-a.nix — node-A (onsite), Design B: LUKS+TPM ZFS-root pool +
# manual-gate ZFS-native-encrypted data pool. DUAL ROLE: onsite DR Garage storage
# + remote devcontainer workstation host (../modules/workstation.nix).
#
# TWO TRUST DOMAINS, one box:
#
#   TPM-AUTO gate (unlocks UNATTENDED in initrd, no console/network needed) —
#   protects ONLY against powered-OFF media theft:
#     NVMe /dev/nvme0n1
#       p1 ESP     1 GiB vfat  -> /boot           (plaintext; Secure-Boot-signed UKIs)
#       p2 swap    8 GiB       (randomEncryption; RAW partition, never a zvol)
#       p3 cryptwork 100%      -> LUKS2 -> zpool `wpool`:
#            wpool/root   -> /               reservation 30G
#            wpool/home   -> /home/sysadmin  reservation 200G
#            wpool/docker -> /var/lib/docker quota 150G
#     LUKS unlock = TPM2 sealed to PCR 7 (auto, keyslot 1) + the install
#     passphrase (recovery, keyslot 0). systemd-initrd unlocks it via crypttab.
#
#   MANUAL gate (ciphertext even when a powered-ON node is stolen) —
#   `zfs load-key` post-boot over the mesh:
#     HDD /dev/sda whole-disk -> zpool `dpool`, ZFS NATIVE aes-256-gcm,
#       keyformat=passphrase, keylocation=prompt:
#         dpool/garage        encryptionroot, mountpoint none
#         dpool/garage/meta   -> /srv/garage/meta      recordsize 16K
#         dpool/garage/data   -> /srv/garage/data-hdd  recordsize 1M
#
# BOOT ORDERING (why root MUST live under the TPM gate, not the manual one):
#   TPM->LUKS unlock (initrd) -> import wpool -> mount wpool/root as / ->
#   switch_root -> stage-2 activation. The node's DEDICATED age key
#   (/var/lib/sops-nix/key.txt, modules/sops.nix age.keyFile) lives on wpool/root,
#   and sops-nix reads it directly. sops-nix MUST decrypt
#   tailscale-authkey + root_password_hash AT ACTIVATION — so wpool has to be
#   unlocked+mounted before stage 2. Putting root under TPM-auto makes that
#   automatic and the node rejoins the tailnet with NO operator present. Only THEN
#   does the operator SSH over the mesh and `zfs load-key dpool/garage`.
#
# INSTALL feeds BOTH encryption secrets non-interactively (no TTY on the remote
# installer). scripts/fleet passes nixos-anywhere TWO --disk-encryption-keys pairs
# against the `.#node-a-install` variant (which sets fleet.zfsInstallKeyfile):
#     --disk-encryption-keys /tmp/fleet-luks.key <local LUKS passphrase file>
#     --disk-encryption-keys /tmp/fleet-zfs.key  <local dpool ZFS passphrase file>
#   * /tmp/fleet-luks.key  -> disko luksFormat keyslot 0  (the LUKS recovery pass)
#   * /tmp/fleet-zfs.key   -> dpool/garage keylocation=file://… at format time
#   These are DELIBERATELY two different passphrases (design: the LUKS recovery
#   keyslot is separate from the dpool ZFS passphrase). Post-boot scripts/fleet:
#     1. systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
#          /dev/disk/by-partlabel/disk-nvme-cryptwork   (adds the TPM keyslot 1;
#          authorised with the keyslot-0 passphrase from /tmp/fleet-luks.key)
#     2. zfs set keylocation=prompt dpool/garage        (restores the manual gate)
#   so neither seed file ever persists on the box.
#
# ⚠️ disko create-mode DESTROYS both disks. Confirm device paths with `lsblk` on
#    the live USB before formatting. Edit the `device =` lines below.
{ config, ... }:
let
  # dpool ZFS-native passphrase: keylocation="prompt" at runtime (the moat); a
  # tmpfs file:// path ONLY during a remote nixos-anywhere install (the
  # `node-a-install` variant sets fleet.zfsInstallKeyfile — flake.nix). Restored
  # to prompt post-boot by scripts/fleet. See modules/base.nix.
  garageKeylocation =
    if config.fleet.zfsInstallKeyfile != null then
      "file://${config.fleet.zfsInstallKeyfile}"
    else
      "prompt";

  # cryptwork LUKS install-time password. Gates on the SAME install signal as the
  # ZFS keyfile (fleet.zfsInstallKeyfile != null ⇒ we are in the `-install`
  # variant) but points at a SEPARATE upload path, because LUKS and dpool use
  # different passphrases. disko reads it as the luksFormat --key-file, seeding
  # keyslot 0 (luks.nix:35-44 keyFileArgs, luks.nix:244 luksFormat). At RUNTIME
  # this is null → disko's askPassword defaults true (luks.nix:118-127), which is
  # harmless: disko's format/open scripts never run at normal boot. Boot unlock is
  # driven entirely by the generated boot.initrd.luks.devices entry + TPM crypttab
  # (below), which is identical in both variants.
  luksInstallKeyfile = if config.fleet.zfsInstallKeyfile != null then "/tmp/fleet-luks.key" else null;
in
{
  # Expose the LUKS install path so scripts/fleet knows this node needs a SECOND
  # --disk-encryption-keys pair (the LUKS passphrase, distinct from the dpool ZFS
  # one). null on the runtime variant and on every non-LUKS node.
  fleet.luksInstallKeyfile = luksInstallKeyfile;

  disko.devices = {
    disk = {
      # --- NVMe: ESP + swap + cryptwork(LUKS)->wpool (TPM-auto trust domain) ---
      nvme = {
        type = "disk";
        device = "/dev/nvme0n1"; # TODO operator: confirm with `lsblk`
        content = {
          type = "gpt";
          partitions = {
            # Explicit priorities pin partition NUMBERS to the design (p1/p2/p3):
            # lib.sort is not stability-guaranteed for equal priorities
            # (gpt.nix:11, :103-120, :244-249). Lower = created first.
            ESP = {
              priority = 1;
              type = "EF00";
              # 2 GiB, not 1: each lanzaboote generation is a standalone signed UKI
              # embedding the FULL systemd+ZFS+cryptsetup+tpm2 initrd (~80-135 MB),
              # and configurationLimit=10 (base.nix) retains up to 10 → ~0.8-1.35 GiB.
              # A 1 GiB ESP can fill and then `lzbt install` fails with ENOSPC on the
              # next deploy — updates wedge until /boot is pruned. 2 GiB is 1 GiB of
              # the ~467 GiB NVMe (0.2%); a bricked bootloader is the worse trade.
              size = "2G";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            # RAW partition, NEVER a zvol: swap on a ZFS zvol deadlocks under
            # memory pressure (ZFS must allocate to free the very page being
            # evicted). randomEncryption: fresh key per boot → swap is unreadable
            # offline, so evicted RAM (which can hold the typed dpool passphrase
            # or decrypted Garage bytes) never leaks from a powered-off disk, yet
            # the node still boots UNATTENDED (no passphrase for swap). Rules out
            # hibernation; headless node, so resumeDevice stays unset.
            #
            # disko wires swapDevices[].device to this partition's by-partlabel
            # path (gpt.nix:82-90; disko swap.nix:118-138). nixpkgs config/swap.nix
            # asserts randomEncryption devices must NOT be by-uuid/by-label
            # (swap.nix:242-250) — by-partlabel satisfies it.
            swap = {
              priority = 2;
              size = "8G";
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };
            # 100% → sorted last (gpt.nix:106) → /dev/nvme0n1p3.
            cryptwork = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptwork"; # -> /dev/mapper/cryptwork
                # Install-only keyslot-0 seed (see luksInstallKeyfile above); null
                # at runtime. NOT enrollRecovery: we do NOT want disko's random QR
                # recovery key — the OPERATOR's install passphrase (keyslot 0) IS
                # the recovery secret (kept for firmware/kernel bumps that change
                # PCR7 and invalidate the TPM keyslot).
                passwordFile = luksInstallKeyfile;
                settings = {
                  # Merged verbatim into boot.initrd.luks.devices.cryptwork
                  # (luks.nix:344-356). crypttabExtraOpts is emitted into the
                  # systemd-initrd crypttab (luksroot.nix:590-611) and is
                  # "Only used with systemd stage 1" (luksroot.nix:996-1006) — so
                  # boot.initrd.systemd.enable MUST be true (set in node-a.nix).
                  # `tpm2-device=auto` is the systemd TPM2 auto-unlock, the exact
                  # mechanism the FIDO2 assertion documents for tokens enrolled out
                  # of band via systemd-cryptenroll (luksroot.nix:1111-1119). Falls
                  # back to the keyslot-0 passphrase prompt if the TPM refuses
                  # (PCR7 changed).
                  crypttabExtraOpts = [ "tpm2-device=auto" ];
                  # NVMe TRIM through dm-crypt: this pool is the dev surface under
                  # heavy container-layer churn, and it is the low-value NON-moat
                  # disk, so the (minor) unused-block leak is an accepted trade for
                  # SSD longevity. Also threads --allow-discards into disko's own
                  # open path (luks.nix:55).
                  allowDiscards = true;
                };
                content = {
                  type = "zfs";
                  pool = "wpool";
                };
              };
            };
          };
        };
      };

      # --- HDD: whole disk → dpool (all Garage; MANUAL gate) ------------------
      hdd = {
        type = "disk";
        device = "/dev/sda"; # TODO operator: confirm with `lsblk`
        content = {
          type = "zfs";
          pool = "dpool";
        };
      };
    };

    zpool = {
      # NVMe workstation + OS pool, on top of LUKS (TPM-auto). NAMED `wpool` (NOT
      # `npool`): node-B's `npool` is its ENCRYPTED Garage SSD pool — reusing that
      # name for the dev/OS pool would mislead a moat audit. rootFsOptions.
      # mountpoint="none" is the root-on-ZFS idiom (disko example
      # zfs-encrypted-root.nix:35): the pool's top dataset never mounts, each child
      # carries its own mountpoint, mounted with -o zfsutil (zfs_fs.nix:171-178).
      # acltype=posixacl + xattr=sa are inherited by every child and are what
      # docker's native `zfs` storage driver needs (modules/workstation.nix).
      # rootFsOptions -> `zpool create -O …`, options -> `-o …` (zpool.nix:380-389).
      wpool = {
        type = "zpool";
        mode = "";
        rootFsOptions = {
          mountpoint = "none";
          compression = "zstd";
          "com.sun:auto-snapshot" = "false"; # not the moat; no sanoid here
          acltype = "posixacl";
          xattr = "sa";
        };
        options.ashift = "12";
        # One pool, three siblings. Without limits ZFS hands free space to whoever
        # asks first: docker image churn starves the OS/home (ENOSPC on `git
        # clone`) and vice-versa. GUARANTEE the OS + dev sides with reservations,
        # CAP docker with a quota, leave the rest as shared slack. reservation/
        # quota flow through as `zfs create -o …` (zfs_fs.nix:77-79); all three are
        # live-tunable later (`zfs set`), unlike the fixed partition sizes above.
        # NONE carry nofail/noauto: they are NOT locked at boot — they auto-mount
        # the instant TPM unlocks cryptwork in initrd, so they must mount normally
        # (wpool/root IS the root fs). Adding nofail/noauto here would be wrong (it
        # is load-bearing ONLY on the locked dpool datasets, below).
        datasets = {
          "root" = {
            type = "zfs_fs";
            mountpoint = "/"; # -> fileSystems."/" device=wpool/root, -o zfsutil
            options.reservation = "30G";
          };
          "home" = {
            type = "zfs_fs";
            mountpoint = "/home/sysadmin"; # sysadmin home (source, build caches)
            # GUARANTEE: docker can never take this 200G, however hard it churns.
            options.reservation = "200G";
          };
          # dockerd's data-root MUST be its own dataset: the native `zfs` driver
          # (modules/workstation.nix) creates one child dataset per image layer
          # under here. Left on wpool/root it would fight the OS for space.
          "docker" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/docker";
            # CEILING: dangling layers accumulate between weekly autoPrune runs.
            # Hitting this fails a build; without it, it fails the whole pool.
            options.quota = "150G";
          };
        };
      };

      # HDD: ALL of Garage (meta + data) on ONE encryptionroot (dpool/garage),
      # ZFS-native aes-256-gcm, keylocation=prompt → the ransomware/theft moat.
      # meta on the HDD too (LMDB on spinning rust is fine for a DR target). The
      # garage user holds NO `zfs allow` here (modules/zfs-sanoid.nix invariant).
      dpool = {
        type = "zpool";
        mode = "";
        rootFsOptions = {
          # mountpoint=none: the top dpool dataset is an inert container (like wpool);
          # without it ZFS defaults to mountpoint=/dpool canmount=on and mounts an
          # empty /dpool every boot. Children carry their own explicit mountpoints.
          mountpoint = "none";
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
              keylocation = garageKeylocation; # prompt at runtime; tmpfs file:// only at install
              mountpoint = "none"; # encryptionroot container only
            };
          };
          # ⚠️ `nofail` is LOAD-BEARING — and it must be nofail ALONE, never
          #    "noauto" "nofail". Do not "tidy" either fact away.
          #
          # dpool/garage is keylocation=prompt and node-a.nix sets
          # requestEncryptionCredentials=false, so these datasets are LOCKED at
          # boot BY DESIGN and cannot mount. Without nofail systemd treats them as
          # REQUIRED, local-fs.target FAILS, and the node drops to emergency.target
          # — no sshd, so the "unlock post-boot over the mesh" this design rests on
          # becomes impossible.
          #
          # Why NOT also noauto: nixpkgs zfs.nix wires zfs-import-<pool>.service
          #   requiredBy = poolMounts ++ optional (!noauto) "zfs-import.target"
          # where noauto = ALL of the pool's filesystems carry "noauto"
          # (zfs.nix:178-183). Every dpool filesystem is a garage dataset, so
          # adding noauto drops dpool out of zfs-import.target — nothing then pulls
          # the import in, the POOL never imports, and `zfs load-key dpool/garage`
          # fails "dataset does not exist" despite boot.zfs.extraPools listing it.
          # (Observed on node-A's first install.)
          #
          # nofail alone gives both: the pool imports, the mount is attempted and
          # fails harmlessly (that IS the pool being locked), boot completes, sshd
          # comes up. After `zfs load-key` the datasets mount (zfs_fs.nix:122-128
          # load-key + mount); garage.service gates on ConditionPathIsMountPoint.
          "garage/meta" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/meta";
            mountOptions = [ "nofail" ];
            options.recordsize = "16K";
          };
          "garage/data" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/data-hdd";
            mountOptions = [ "nofail" ];
            options.recordsize = "1M";
          };
        };
      };
    };
  };
}
