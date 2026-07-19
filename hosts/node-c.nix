# hosts/node-c.nix — OFFSITE-2 storage + Tailscale scraper-egress proxy.
# doc 00 §3, doc 01 Phase 2. SAME hardware as node-B (AMD Lenovo, NVMe 500GB +
# HDD 1TB), dual-disk npool + dpool via its OWN disko-node-c.nix; different
# zone/IP/hostId. Installed INTERACTIVELY from a NixOS live USB (doc 03 / doc 04).
{ ... }:
{
  imports = [
    ./disko-node-c.nix
    ./node-c-hardware.nix # same hardware as node-B (reuses node-b-hardware.nix)
  ];

  networking.hostName = "node-c";
  # TODO operator: unique 8-hex-digit ZFS hostId. MUST differ from node-A/-B.
  networking.hostId = "deadbee3";

  # Both data pools import at boot; their datasets stay LOCKED until you
  # `zfs load-key -a` post-boot over the tailnet (keylocation=prompt).
  boot.zfs.extraPools = [
    "npool"
    "dpool"
  ];
  # Do NOT block boot waiting for a passphrase — unlock happens post-boot.
  boot.zfs.requestEncryptionCredentials = false;

  # --- 4 GB RAM budget (same box as node-B) ----------------------------------
  # Cap ARC at 1 GiB so it does not crowd Garage out of a 4 GB box (node-B note).
  boot.extraModprobeConfig = "options zfs zfs_arc_max=1073741824";
  # Compressed RAM swap, no disk swap — same rationale as node-B (LMDB is mmap'd,
  # zram leaks nothing, root is unencrypted ext4).
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  fleet = {
    role = "storage";
    zone = "offsite-2";
    garageCapacity = "1000GB"; # advertised to the Garage layout (fleet layout apply)
    proxyNode = true; # carries the Tailscale scraper-egress proxy role
    zfsAutoUnlock = false; # prompt-unlock; no passphrase on box
    # TODO operator: node-C's tailscale0 overlay IP (100.x.x.C) — set AFTER join.
    tailscaleIp = "100.92.142.13";

    # Cluster gossip: A (onsite) + B (offsite-1) `garage node id`s. Persists the
    # peering across reboots so C re-forms the cluster over the tailnet on boot.
    bootstrapPeers = [
      "aef46cd13cbcf4045114bae5d36bbfcf16c5dc774ef12610e59f5c2014acd594@100.122.58.119:3901" # node-a
      "211f2649528a4b96f9ce8f4bab58531777d96fdd7859633ff02b7f7f4aba9556@100.122.210.124:3901" # node-b
    ];

    # TODO operator: LAN subnet this proxy advertises (scraper-egress role),
    # e.g. [ "192.168.1.0/24" ]. Leave [] until you wire the proxy route.
    advertiseRoutes = [ ];

    # Garage spans NVMe (ssd) + HDD, matching node-A's ~75%-of-usable ratio so the
    # pool keeps ~25% headroom for garage/meta + 90 days of sanoid snapshots (the
    # moat — node-a.nix:96-101). Nominal usable: npool ≈ 405 GiB, dpool ≈ 931 GiB.
    # TODO operator: retune after `zpool list` on the real box.
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

  # ⚠️ Same offsite whole-box-theft boot-trust note as node-b (doc 00 §7).

  # Layout: garage layout assign <id-C> -z offsite-2 -c <bytes>  (doc 01 P2)
}
