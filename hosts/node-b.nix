# hosts/node-b.nix — OFFSITE-1 storage + Tailscale scraper-egress proxy.
# doc 09 §3, doc 10 Phase 2.
#
# Storage role + proxyNode=true (advertises subnet route / exit node). Imports
# the encrypted ZFS pool + zfs-sanoid moat + garage(storage) + tailscale.
{ ... }:
{
  imports = [
    ./disko-storage.nix
    ../modules/zfs-sanoid.nix
    # TODO operator: ./node-b-hardware.nix (generated at install)
  ];

  networking.hostName = "node-b";
  # TODO operator: unique 8-hex-digit ZFS hostId.
  networking.hostId = "deadbee2";

  fleet = {
    role = "storage";
    zone = "offsite-1";
    proxyNode = true; # carries the Tailscale scraper-egress proxy role
    # TODO operator: node-B's tailscale0 overlay IP (100.x.x.B).
    tailscaleIp = "100.64.0.11";
  };

  sops.secrets."tailscale-authkey".sopsFile = ../secrets/node-b-tailscale.sops.yaml;

  # ⚠️ Whole-box theft is most plausible at unattended offsite sites (doc 09 §7
  #    boot-trust note). disko-storage.nix auto-unlocks at boot. To keep node-B
  #    LOCKED if stolen, switch its bpool/garage keylocation to "prompt" /
  #    initrd-SSH unlock (opt-in, accept reboot toil). Default here: auto-unlock.

  # Layout: garage layout assign <id-B> -z offsite-1 -c <bytes>  (doc 10 P2)
}
