# hosts/disko-node-a.nix — node-A (onsite), interactive USB install (doc 13).
# DUAL ROLE: onsite DR Garage storage + remote devcontainer workstation
# (modules/workstation.nix, driven from a Mac via DevPod). The two roles get
# SEPARATE disks so the dev surface never shares a pool with the backup moat:
#
#   NVMe  = ESP + UNENCRYPTED ext4 root + UNENCRYPTED `wpool` (dev/podman home).
#           No passphrase → the node boots SSH/DevPod-reachable UNATTENDED.
#   HDD   = encrypted `dpool` = ALL of Garage (meta + data), keylocation="prompt"
#           → unlocked post-boot with `zfs load-key dpool/garage` over the mesh.
#
# WHY NVMe IS UNENCRYPTED: it holds dev source + container layers, NOT the
# backups — and onsite whole-box theft is the low-risk case (vs the offsite
# nodes). Keeping it unencrypted is what lets the workstation come up without a
# console operator. To encrypt it anyway, give `wpool` an encryptionroot with
# `keylocation = "file://…"` pointing at a sops `zfs-passphrase` + a boot
# load-key unit (the fleet.zfsAutoUnlock pattern) — left out for simplicity.
#
# ⚠️ disko create-mode DESTROYS both disks. Confirm device paths with `lsblk` on
#    the live USB before formatting — node-A's disks MAY differ (e.g. /dev/sdb,
#    or a single NVMe). Edit the `device =` lines below.
{ config, ... }:
let
  # keylocation="prompt" at runtime (the moat); a tmpfs file:// path ONLY during
  # a remote nixos-anywhere install (set by the `<node>-install` flake variant,
  # restored to prompt post-boot by scripts/fleet). See modules/base.nix.
  garageKeylocation =
    if config.fleet.zfsInstallKeyfile != null then
      "file://${config.fleet.zfsInstallKeyfile}"
    else
      "prompt";
in
{
  disko.devices = {
    disk = {
      # --- NVMe: ESP + ext4 root + wpool (dev workstation pool) -------------
      nvme = {
        type = "disk";
        device = "/dev/nvme0n1"; # TODO operator: confirm with `lsblk`
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
              size = "60G"; # OS root; the rest of the NVMe → wpool (dev)
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
            # A PLAIN partition, never a zvol: swap on a ZFS zvol deadlocks under
            # memory pressure (ZFS must allocate to free the very page being
            # evicted). 8G backs container builds; ARC is capped at 4 GiB
            # (modules/workstation.nix), leaving ~12G to dev.
            #
            # randomEncryption: this NVMe is UNENCRYPTED by design (see header), but
            # swap holds evicted RAM — which can include the dpool passphrase typed
            # at `zfs load-key` and decrypted Garage bytes. A fresh random key per
            # boot makes swap unreadable offline WITHOUT a passphrase, so the node
            # still boots unattended for DevPod. Rules out hibernation; headless
            # node, so `resumeDevice` is deliberately unset.
            swap = {
              size = "8G";
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "wpool";
              };
            };
          };
        };
      };

      # --- HDD: whole disk → dpool (all Garage) ----------------------------
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
      # NVMe: UNENCRYPTED workstation pool. NAMED `wpool` (NOT `npool`) on purpose:
      # node-B's `npool` is the ENCRYPTED Garage SSD pool — reusing that name here
      # for an unencrypted dev pool would mislead a moat audit. Mounts at boot with
      # NO passphrase so the node is reachable for DevPod unattended. posixacl +
      # xattr=sa let
      # rootless podman's overlay storage driver run on ZFS (modules/workstation.nix
      # puts the dev user's home — and thus the container graphroot — on wpool/dev).
      wpool = {
        type = "zpool";
        mode = "";
        rootFsOptions = {
          compression = "zstd";
          "com.sun:auto-snapshot" = "false"; # not the moat; no sanoid here
          acltype = "posixacl";
          xattr = "sa";
        };
        options.ashift = "12";
        # wpool ≈ 408 GiB (476.9 NVMe - 0.5 ESP - 60 root - 8 swap). `dev` and
        # `docker` are siblings in ONE pool, so without limits ZFS hands space to
        # whoever asks first: a week of devcontainer image churn fills the pool and
        # `git clone` starts failing with ENOSPC (and vice versa). Reserve the dev
        # side, cap the docker side, leave ~50G of slack either can borrow.
        # Both are live-tunable later (`zfs set quota=… / reservation=…`) — unlike
        # the partition sizes above, which are fixed at format.
        datasets = {
          "dev" = {
            type = "zfs_fs";
            mountpoint = "/home/dev"; # dev user home (source, build caches)
            # GUARANTEE: docker can never take this 200G, however badly it churns.
            options.reservation = "200G";
          };
          # Docker's data-root. MUST be its own dataset on wpool: dockerd uses the
          # native `zfs` storage driver (modules/workstation.nix) and creates one
          # child dataset per image layer under here. Left at the default
          # /var/lib/docker it would fill the 60G ext4 root instead of the NVMe pool.
          "docker" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/docker";
            # CEILING: dangling layers accumulate between weekly autoPrune runs.
            # `docker` hitting this fails a build; without it, it fails the POOL.
            options.quota = "150G";
          };
        };
      };

      # HDD: ALL of Garage (meta + data) on ONE encryptionroot (dpool/garage),
      # keylocation="prompt" → the ransomware moat. meta on the HDD too (LMDB on
      # spinning rust is fine for a DR target). garage user holds NO zfs allow
      # here (modules/zfs-sanoid.nix invariant).
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
              keylocation = garageKeylocation; # prompt at runtime; tmpfs file:// only at install
              mountpoint = "none"; # container only
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
          # where noauto = ALL of the pool's filesystems carry "noauto". Every
          # dpool filesystem is a garage dataset, so adding noauto drops dpool out
          # of zfs-import.target — nothing then pulls the import in, the POOL never
          # imports, and `zfs load-key dpool/garage` fails "dataset does not exist"
          # despite boot.zfs.extraPools listing it. (Observed on node-A's first
          # install.) node-B/-C are worse: every one of their pools is garage-only,
          # so NO data pool would import at all, offsite.
          #
          # nofail alone gives both: the pool imports, the mount is attempted and
          # fails harmlessly (journal shows it — that IS the pool being locked),
          # boot completes, sshd comes up. `zfs mount -a` after `zfs load-key`
          # mounts them; garage.service gates on ConditionPathIsMountPoint.
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
