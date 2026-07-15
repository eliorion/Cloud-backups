# hosts/disko-storage.nix — declarative disk + ZFS layout for STORAGE nodes
# (A/B/C). Imported by node-a/-b/-c (doc 09 §5/§7, doc 10 Phase 1 disko skeleton).
#
# One ZFS pool `bpool` with the encryption boundary at `bpool/garage` and
# separate meta (small recordsize) + data (large recordsize) datasets on which
# Garage stores metadata + data — node-local ZFS, NOT Longhorn, to break the
# backing-up-the-thing-you-back-up circular dependency (doc 09 §5).
#
# ⚠️ disko create-mode DESTROYS the target disk. Only ever run nixos-anywhere on
#    a node BEFORE it holds backups (doc 10 risk register).
#
# BOOT-TRUST CAVEAT (doc 09 §7, doc 10 Phase 1 boot-trust note):
#   keylocation = file://… + a sops-nix-persisted passphrase means the node
#   AUTO-UNLOCKS at boot — the age identity that decrypts the passphrase lives
#   on the same disk (derived from the on-disk SSH host key). So ZFS-at-rest
#   here protects ONLY against media-only theft (a pulled platter / RMA'd disk),
#   NOT whole-box theft. The unattended offsite nodes (B/C) are exactly where
#   whole-box theft is most plausible. We ACCEPT auto-unlock; the real theft
#   mitigation is client-side payload encryption on the restic/Kopia paths
#   (Garage stores only ciphertext for those). To keep a stolen offsite box
#   LOCKED instead, switch that node to keylocation=prompt or initrd-SSH /
#   Tailscale remote unlock and accept the unattended-reboot toil (opt-in).
#
# ⚠️ KEY PERSISTENCE — file:///tmp/zfs.key BELOW IS INSTALL-SEED-ONLY.
#   disko/nixos-anywhere uses keylocation to load the key at POOL CREATION (the
#   seed file passed via --disk-encryption-keys). /tmp is tmpfs and the seed is
#   GONE after the first reboot, so as written the node will NOT reboot-unlock —
#   and a plaintext passphrase under world-traversable /tmp is itself a leak. The
#   documented "persisted via sops-nix" model is NOT satisfied by this line
#   alone. The operator MUST, before relying on reboot-unlock:
#     1. put the real passphrase in secrets/common.enc.yaml under `zfs-passphrase`
#        (declared as a sops-nix secret in modules/sops.nix, owner root 0400), and
#     2. either repoint keylocation at the decrypted secret path
#        (file://${config.sops.secrets."zfs-passphrase".path}) once sops-nix has
#        materialised it, OR add a boot-time systemd unit that runs
#        `zfs load-key bpool/garage` from that path, ordered after sops-nix.
#   Until then treat /tmp/zfs.key as the install seed only and expect a manual
#   `zfs load-key` after any reboot. The at-rest-encryption claim (media-only
#   theft) holds only once the key lives encrypted-at-rest via sops-nix, not /tmp.
{ config, lib, ... }:
let
  # keylocation="prompt" at runtime (the prompt-unlock fleet default, CLAUDE.md);
  # a tmpfs file:// path ONLY during a remote nixos-anywhere install (set by the
  # `<node>-install` flake variant, restored to prompt post-boot by scripts/fleet,
  # modules/base.nix). This REPLACES the old hardcoded file:///tmp/zfs.key seed —
  # which never survived a reboot — so node-C now prompt-unlocks like A/B. For an
  # AUTO-unlock offsite node, wire fleet.zfsAutoUnlock + the sops zfs-passphrase
  # secret instead (modules/sops.nix), not a /tmp seed.
  garageKeylocation =
    if config.fleet.zfsInstallKeyfile != null then
      "file://${config.fleet.zfsInstallKeyfile}"
    else
      "prompt";
in
{
  disko.devices = {
    disk = {
      # Boot/OS disk. TODO operator: set per-host device path (e.g. /dev/nvme0n1
      # or /dev/sda) — varies by hardware; override in the host file if needed.
      boot = {
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
            # Root on its own (unencrypted) ZFS or ext4 keeps this skeleton
            # simple; the SENSITIVE data lives on the encrypted bpool/garage
            # datasets below. TODO operator: enlarge / split as hardware dictates.
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      # Garage data disk(s). TODO operator: set per-host device path and, for
      # multi-disk nodes, change zpool `mode` to "mirror"/"raidz1" and list all
      # member disks here.
      data = {
        type = "disk";
        device = lib.mkDefault "/dev/sdb";
        content = {
          type = "zfs";
          pool = "bpool";
        };
      };
    };

    zpool.bpool = {
      type = "zpool";
      mode = ""; # single disk; "mirror"/"raidz1" if multiple data members
      rootFsOptions = {
        compression = "zstd";
        "com.sun:auto-snapshot" = "false"; # sanoid owns snapshots, not zfs-auto
        acltype = "posixacl";
        xattr = "sa";
      };
      options.ashift = "12";

      datasets = {
        # Encryption boundary. Native aes-256-gcm (preferred over LUKS) so
        # `zfs send -w` ships still-encrypted ciphertext to an offsite vault
        # (doc 09 §7). Trade-off: native encryption leaks pool-level metadata
        # (dataset/snapshot names, sizes) — accepted for the raw-send property.
        "garage" = {
          type = "zfs_fs";
          options = {
            encryption = "aes-256-gcm";
            keyformat = "passphrase";
            keylocation = garageKeylocation; # prompt at runtime; tmpfs file:// only at install
          };
        };
        # Garage metadata (LMDB) — small recordsize. Size for LMDB + Garage
        # metadata snapshots, which can transiently need ~4x the DB size
        # (doc 09 §11). Put on SSD where possible.
        # ⚠️ noauto+nofail is LOAD-BEARING — see the long note in
        # hosts/disko-node-a.nix. Locked-at-boot datasets declared as REQUIRED
        # mounts fail local-fs.target and strand the node in emergency.target with
        # no sshd. On an OFFSITE node that means a site visit.
        "garage/meta" = {
          type = "zfs_fs";
          mountpoint = "/srv/garage/meta";
          mountOptions = [
            "noauto"
            "nofail"
          ];
          options.recordsize = "16K";
        };
        # Garage object data — large recordsize + compression.
        "garage/data" = {
          type = "zfs_fs";
          mountpoint = "/srv/garage/data";
          mountOptions = [
            "noauto"
            "nofail"
          ];
          options.recordsize = "1M";
        };
      };
    };
  };
}
