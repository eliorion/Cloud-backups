# hosts/disko-node-b.nix — node-B (offsite-1), interactive USB install (doc 12).
# NVMe = ESP + UNENCRYPTED ext4 root + encrypted `npool` (meta + ssd data).
# HDD  = encrypted `dpool` (bulk data). keylocation="prompt": disko asks for the
# passphrase at format, and you re-enter it post-boot to unlock (never stored).
#
# ⚠️ disko create-mode DESTROYS both disks. Only ever run on a node BEFORE it
#    holds backups (doc 10 risk register). Confirm device paths with `lsblk` on
#    the live USB before §5 of doc 13 / doc 12.
{ config, ... }:
let
  # keylocation="prompt" at runtime (the moat); a tmpfs file:// path ONLY during
  # a remote nixos-anywhere install (set by the `<node>-install` flake variant,
  # restored to prompt post-boot by scripts/fleet). Both encryptionroots
  # (npool/garage + dpool/garage) read the SAME uploaded keyfile → one passphrase.
  garageKeylocation =
    if config.fleet.zfsInstallKeyfile != null then
      "file://${config.fleet.zfsInstallKeyfile}"
    else
      "prompt";
in
{
  disko.devices = {
    disk = {
      # --- NVMe 500GB: ESP + ext4 root + npool ------------------------------
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
              size = "60G"; # OS root; the rest of the NVMe → npool
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
        device = "/dev/sda"; # TODO operator: confirm with `lsblk`
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
          "com.sun:auto-snapshot" = "false"; # sanoid owns snapshots
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
          # ⚠️ noauto+nofail is LOAD-BEARING — see the long note in
          # hosts/disko-node-a.nix. Locked-at-boot datasets declared as REQUIRED
          # mounts fail local-fs.target and strand the node in emergency.target
          # with no sshd. On an OFFSITE node that means a site visit.
          "garage/meta" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/meta";
            mountOptions = [
              "noauto"
              "nofail"
            ];
            options.recordsize = "16K";
          };
          "garage/data" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/data-ssd";
            mountOptions = [
              "noauto"
              "nofail"
            ];
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
              keylocation = garageKeylocation; # prompt at runtime; tmpfs file:// only at install
              mountpoint = "none";
            };
          };
          # ⚠️ noauto+nofail load-bearing — see hosts/disko-node-a.nix.
          "garage/data" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/data-hdd";
            mountOptions = [
              "noauto"
              "nofail"
            ];
            options.recordsize = "1M";
          };
        };
      };
    };
  };
}
