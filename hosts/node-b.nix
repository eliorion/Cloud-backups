# hosts/node-b.nix — OFFSITE-1 storage + Tailscale scraper-egress proxy.
# Installed INTERACTIVELY from a NixOS live USB (doc 12 / doc 13), NOT
# dd/nixos-anywhere. Dual-disk (NVMe npool + HDD dpool), prompt-unlock.
{ ... }:
{
  imports = [
    ./disko-node-b.nix
    ./node-b-hardware.nix
    ../modules/zfs-sanoid.nix
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

  fleet = {
    role = "storage";
    zone = "offsite-1";
    proxyNode = true;
    zfsAutoUnlock = false; # prompt-unlock; no passphrase on box

    # TODO operator: node-B's tailscale0 overlay IP — set AFTER first join (doc 12 §7).
    tailscaleIp = "100.64.0.11";

    # TODO operator: LAN subnet this proxy advertises (scraper-egress role),
    # e.g. [ "192.168.1.0/24" ]. Leave [] until you wire the proxy route.
    advertiseRoutes = [ ];

    # Garage spans NVMe (ssd) + HDD. Capacities ≈ usable space, tune after
    # `zpool list`. sanoid snapshots BOTH data pools (the moat).
    dataDirs = [
      {
        path = "/srv/garage/data-ssd";
        capacity = "400G";
      }
      {
        path = "/srv/garage/data-hdd";
        capacity = "900G";
      }
    ];
    sanoidDatasets = [
      "npool/garage"
      "dpool/garage"
    ];
  };

  sops.secrets."tailscale-authkey".sopsFile = ../secrets/node-b-tailscale.sops.yaml;
}
