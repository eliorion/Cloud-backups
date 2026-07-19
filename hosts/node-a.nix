# hosts/node-a.nix — ONSITE storage node (zone onsite). doc 00 §3, doc 04.
#
# DUAL ROLE: onsite DR Garage storage AND a remote devcontainer workstation
# (../modules/workstation.nix, driven from a Mac via DevPod). Installed
# INTERACTIVELY from a NixOS live USB (doc 04). TWO trust domains, split by disk:
#
#   NVMe = LUKS2 (cryptwork) -> ZFS `wpool` -> wpool/{root,home,docker}. The
#     TPM-AUTO domain: unsealed unattended in initrd (TPM2 bound to PCR 7, no
#     console, no mesh), so root/home/docker come up on their own and the node is
#     SSH/DevPod-reachable after a bare reboot. Signed UKIs + Secure Boot
#     (../modules/secureboot.nix, lanzaboote) lock the boot path so a thief cannot
#     edit the kernel cmdline to get a shell on the decrypted root. Protects only
#     against powered-OFF media theft.
#   HDD = ZFS-native-encrypted `dpool` = ALL of Garage (meta + data). The MANUAL
#     gate: keylocation=prompt, stays ciphertext until the operator runs
#     `zfs load-key dpool/garage` over the mesh POST-boot (the moat). Ciphertext
#     even if a powered-ON node is stolen.
#
# Storage role, NOT a proxy.
{ ... }:
{
  imports = [
    ./disko-node-a.nix
    ./node-a-hardware.nix
    ../modules/workstation.nix
    ../modules/secureboot.nix # node-A ONLY: lanzaboote signed UKIs + Secure Boot
  ];

  networking.hostName = "node-a";
  # ZFS requires a unique 8-hex-digit hostId. TODO operator: set a real one
  # (e.g. `head -c4 /dev/urandom | od -A none -t x4`). Must differ from node-B's.
  networking.hostId = "a0c1d2e3";

  # wpool is the ROOT pool now (LUKS2-on-NVMe → wpool → wpool/root = /). It is
  # imported IN INITRD as a root pool, after the TPM2 unseals the cryptwork LUKS key
  # (unattended, no console, no mesh), so it does NOT belong in extraPools — the
  # root fileSystems entry pulls it in. Only dpool (the HDD Garage data pool,
  # imported in stage 2) is listed here. This is technically redundant — dpool is
  # already in `allPools` via its garage/meta + garage/data fileSystems entries
  # (disko emits those for any dataset with a real mountpoint) — but it is kept as
  # an explicit belt-and-suspenders so the pool still imports if those datasets ever
  # move to mountpoint=none.
  boot.zfs.extraPools = [ "dpool" ];

  # false = do NOT request ZFS encryption credentials at boot. wpool carries no ZFS
  # encryption (LUKS handles it at the block layer), and dpool/garage is
  # keylocation=prompt but must stay LOCKED until the operator unlocks it over the
  # mesh. With this false, nixpkgs zfs.nix skips systemd-ask-password for every pool
  # (getKeyLocations.hasKeys = false), so the stage-2 dpool import does NOT block
  # boot waiting for a passphrase; dpool imports and its garage/* mounts fail
  # harmlessly (nofail, hosts/disko-node-a.nix). Operator then runs, over the mesh:
  #     zfs load-key dpool/garage && zfs mount -a
  # → garage.service's ConditionPathIsMountPoint clears and Garage starts. This is
  # the ONLY manual post-reboot step; the mesh rejoin itself is automatic (below).
  boot.zfs.requestEncryptionCredentials = false;

  # systemd stage-1 initrd is REQUIRED here, for two independent reasons:
  #   1. TPM2 auto-unlock of the cryptwork LUKS volume (crypttab tpm2-device=auto,
  #      wired by ../modules/secureboot.nix) only runs under systemd initrd. disko's
  #      luks type only auto-enables this for FIDO2, not TPM2, so we set it here.
  #   2. The ZFS root-import service that unlocks-imports wpool and mounts wpool/root
  #      as / is only emitted under systemd initrd (nixpkgs zfs.nix gates
  #      createImportService on boot.initrd.systemd.enable); the legacy scripted
  #      importer has no LUKS/TPM path.
  # secureboot.nix may also assert/set this true — equal-value bool defs merge, so
  # the duplication is harmless.
  boot.initrd.systemd.enable = true;

  fleet = {
    role = "storage";
    zone = "onsite";
    garageCapacity = "700GB"; # advertised to the Garage layout (fleet layout apply)
    proxyNode = false; # onsite node carries NO Tailscale scraper-egress proxy
    # Fleet default = prompt-unlock (doc 04). Kept false to match the rest of the
    # fleet. NOTE: flipping this to true is NOT sufficient to auto-unlock dpool on
    # node-A — it only declares the sops zfs-passphrase secret. To actually skip
    # the per-reboot unlock you must also switch dpool/garage keylocation to a
    # file://… URL in disko-node-a.nix and add a boot load-key unit (modules/sops.nix
    # TODO). The wpool is TPM2/LUKS-unlocked in initrd, independent of this toggle.
    zfsAutoUnlock = false;

    # Secure Boot (lanzaboote signed UKIs). true ONLY after `sbctl create-keys` ran
    # on the box (modules/secureboot.nix runbook §3): this deploy signs the UKIs and
    # drops systemd-boot; then enroll keys + enable SB in firmware + seal the TPM at
    # the console (§5-8). Flipping true before the keys exist = unbootable box.
    secureBoot = true;

    # TODO operator: node-A's tailscale0 overlay IP — set AFTER first join (doc 04).
    tailscaleIp = "100.122.58.119";

    # Cluster gossip: every OTHER node's `garage node id`. B (offsite-1) here; add
    # C (offsite-2) once it is installed. Persists the peering across reboots.
    bootstrapPeers = [
      "211f2649528a4b96f9ce8f4bab58531777d96fdd7859633ff02b7f7f4aba9556@100.122.210.124:3901" # node-b
    ];

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
    # Moat: sanoid snapshots the one Garage pool. wpool datasets are NOT moat data.
    sanoidDatasets = [
      "dpool/garage"
    ];
  };

  # Per-node Tailscale auth key file (see modules/sops.nix + secrets/.example).

  # Garage capacity for this node's layout assignment is applied imperatively:
  #   garage layout assign <id-A> -z onsite -c <bytes>   (doc 04 Phase A)
}
