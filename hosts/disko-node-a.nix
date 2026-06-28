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
        datasets = {
          "dev" = {
            type = "zfs_fs";
            mountpoint = "/home/dev"; # dev user home → podman graphroot lives here
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
          "garage/meta" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/meta";
            options.recordsize = "16K";
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
