# hosts/node-a.nix — ONSITE storage node (zone onsite). doc 09 §3, doc 13.
#
# DUAL ROLE: onsite DR Garage storage AND a remote devcontainer workstation
# (../modules/workstation.nix, driven from a Mac via DevPod). Installed
# INTERACTIVELY from a NixOS live USB (doc 13). Disks are SPLIT by role:
# NVMe wpool = UNENCRYPTED dev pool (boots unattended); HDD dpool = encrypted,
# prompt-unlock, ALL of Garage (the moat). Storage role, NOT a proxy.
{ ... }:
{
  imports = [
    ./disko-node-a.nix
    ./node-a-hardware.nix
    ../modules/zfs-sanoid.nix
    ../modules/workstation.nix
  ];

  networking.hostName = "node-a";
  # ZFS requires a unique 8-hex-digit hostId. TODO operator: set a real one
  # (e.g. `head -c4 /dev/urandom | od -A none -t x4`). Must differ from node-B's.
  networking.hostId = "a0c1d2e3";

  # Both pools import at boot. wpool (dev) is UNENCRYPTED → mounts immediately so
  # the workstation is reachable. dpool/garage stays LOCKED until
  # `zfs load-key dpool/garage` post-boot over the mesh (keylocation=prompt).
  # Do NOT block boot on the unlock.
  boot.zfs.extraPools = [
    "wpool"
    "dpool"
  ];
  boot.zfs.requestEncryptionCredentials = false;

  fleet = {
    role = "storage";
    zone = "onsite";
    proxyNode = false; # onsite node carries NO Tailscale scraper-egress proxy
    # Fleet default = prompt-unlock (doc 13). Kept false to match the rest of the
    # fleet. NOTE: flipping this to true is NOT sufficient to auto-unlock dpool on
    # node-A — it only declares the sops zfs-passphrase secret. To actually skip
    # the per-reboot unlock you must also switch dpool/garage keylocation to a
    # file://… URL in disko-node-a.nix and add a boot load-key unit (modules/sops.nix
    # TODO). The wpool (dev) is unencrypted and unaffected.
    zfsAutoUnlock = false;

    # TODO operator: node-A's tailscale0 overlay IP — set AFTER first join (doc 13).
    tailscaleIp = "100.64.0.10";

    # ALL Garage data is on the HDD dpool now — the NVMe wpool is the dev
    # workstation pool (../modules/workstation.nix), NOT Garage. Single data_dir.
    # Capacity ≈ usable space; tune after `zpool list`.
    # TODO operator: set real capacity for node-A's HDD.
    dataDirs = [
      {
        path = "/srv/garage/data-hdd";
        # 700G of a 931.5 GiB disk. NOT the raw size: this pool also carries
        # garage/meta AND 90 days of sanoid snapshots (modules/zfs-sanoid.nix) —
        # the ransomware moat. Advertising the full disk fills the pool, snapshots
        # then fail to take, and the moat dies silently. Raise once real churn is
        # visible in `zpool list`; lowering it after the pool wedges is painful.
        capacity = "700G";
      }
    ];
    # Moat: sanoid snapshots the one Garage pool. wpool/dev is NOT a moat dataset.
    sanoidDatasets = [
      "dpool/garage"
    ];
  };

  # Per-node Tailscale auth key file (see modules/sops.nix + secrets/.example).
  sops.secrets."tailscale-authkey".sopsFile = ../secrets/node-a-tailscale.sops.yaml;

  # Garage capacity for this node's layout assignment is applied imperatively:
  #   garage layout assign <id-A> -z onsite -c <bytes>   (doc 13 Phase A)
}
