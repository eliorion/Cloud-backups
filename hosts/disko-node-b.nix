# hosts/disko-node-b.nix — node-B (offsite-1), interactive USB install (doc 03).
# NVMe = ESP + UNENCRYPTED ext4 root + encrypted `npool` (meta + ssd data).
# HDD  = encrypted `dpool` (bulk data). keylocation="prompt": disko asks for the
# passphrase at format, and you re-enter it post-boot to unlock (never stored).
#
# ⚠️ disko create-mode DESTROYS both disks. Only ever run on a node BEFORE it
#    holds backups (doc 01 risk register). Confirm device paths with `lsblk` on
#    the live USB before §5 of doc 04 / doc 03.
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
          # Inert container — suppress the empty /npool|/dpool root mount (node-A
          # parity, hosts/disko-node-a.nix). Children carry explicit mountpoints.
          mountpoint = "none";
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
          # ⚠️ `nofail` ALONE — never add "noauto". See the long note in
          # hosts/disko-node-a.nix: nofail stops a locked-at-boot dataset from failing
          # local-fs.target (which strands the node in emergency.target with no sshd —
          # a site visit, offsite), while adding noauto would drop this pool out of
          # zfs-import.target so it never imports at all.
          "garage/meta" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/meta";
            mountOptions = [ "nofail" ];
            options.recordsize = "16K";
          };
          "garage/data" = {
            type = "zfs_fs";
            mountpoint = "/srv/garage/data-ssd";
            mountOptions = [ "nofail" ];
            options.recordsize = "1M";
          };
        };
      };

      # HDD: second encryptionroot (dpool/garage) → bulk data inherits it.
      dpool = {
        type = "zpool";
        mode = "";
        rootFsOptions = {
          # Inert container — suppress the empty /npool|/dpool root mount (node-A
          # parity, hosts/disko-node-a.nix). Children carry explicit mountpoints.
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
              mountpoint = "none";
            };
          };
          # ⚠️ `nofail` ALONE — never add "noauto". See hosts/disko-node-a.nix.
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
