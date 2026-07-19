# hosts/node-b.nix — OFFSITE-1 storage + Tailscale scraper-egress proxy.
# Installed INTERACTIVELY from a NixOS live USB (doc 03 / doc 04), NOT
# dd/nixos-anywhere. Dual-disk (NVMe npool + HDD dpool), prompt-unlock.
{ ... }:
{
  imports = [
    ./disko-node-b.nix
    ./node-b-hardware.nix
  ];

  networking.hostName = "node-b";
  networking.hostId = "90b2c268"; # unique 8-hex ZFS hostId

  # Both data pools import at boot; their datasets stay LOCKED until you
  # `zfs load-key -a` post-boot over the tailnet (keylocation=prompt).
  boot.zfs.extraPools = [
    "npool"
    "dpool"
  ];
  # Do NOT block boot waiting for a passphrase — unlock happens post-boot.
  boot.zfs.requestEncryptionCredentials = false;

  # --- 4 GB RAM budget -------------------------------------------------------
  # ARC defaults to ~50% of RAM (~2G here) and would crowd Garage out of a 4 GB
  # box. Cap at 1 GiB — this node is a DR target, so cache hit-rate matters far
  # less than headroom. (node-A caps ARC in modules/workstation.nix; that module
  # is node-A-only, so node-B needs its own.)
  boot.extraModprobeConfig = "options zfs zfs_arc_max=1073741824";

  # Compressed RAM swap instead of a swap partition. Deliberately NO disk swap:
  # Garage's dominant consumer is the LMDB meta store (db_engine="lmdb"), which is
  # mmap'd — file-backed, so the kernel evicts it straight back to its own file and
  # never to swap. Disk swap would only absorb anon spikes that zram already takes,
  # at the cost of thrashing a node we cannot physically reach. zram is also the
  # only option that leaks nothing: node-B's root is unencrypted ext4.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  fleet = {
    role = "storage";
    zone = "offsite-1";
    garageCapacity = "1000GB"; # advertised to the Garage layout (fleet layout apply)
    proxyNode = true;
    zfsAutoUnlock = false; # prompt-unlock; no passphrase on box

    # TODO operator: node-B's tailscale0 overlay IP — set AFTER first join (doc 03 §7).
    tailscaleIp = "100.122.210.124";

    # Cluster gossip: every OTHER node's `garage node id`. A (onsite) here; add
    # C (offsite-2) once it is installed. Persists the peering across reboots.
    bootstrapPeers = [
      "aef46cd13cbcf4045114bae5d36bbfcf16c5dc774ef12610e59f5c2014acd594@100.122.58.119:3901" # node-a
    ];

    # TODO operator: LAN subnet this proxy advertises (scraper-egress role),
    # e.g. [ "192.168.1.0/24" ]. Leave [] until you wire the proxy route.
    advertiseRoutes = [ ];

    # Garage spans NVMe (ssd) + HDD. Capacities ≈ usable space, tune after
    # `zpool list`. sanoid snapshots BOTH data pools (the moat).
    # Matches node-A's ~75%-of-usable ratio so each pool keeps ~25% headroom for
    # garage/meta + 90 days of sanoid snapshots (the moat — node-a.nix:96-101).
    # Previous 400G/900G advertised ~99%/~97% of the pools, starving snapshots.
    # Nominal usable: npool ≈ 405 GiB, dpool ≈ 931 GiB. Retune after `zpool list`.
    dataDirs = [
      {
        path = "/srv/garage/data-ssd";
        capacity = "300G"; # ~75% of npool (meta + snapshots take the rest)
      }
      {
        path = "/srv/garage/data-hdd";
        capacity = "700G"; # matches node-A's HDD (700G of ~931 GiB)
      }
    ];
    sanoidDatasets = [
      "npool/garage"
      "dpool/garage"
    ];
  };

}
