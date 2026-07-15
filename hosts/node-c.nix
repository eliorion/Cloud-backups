# hosts/node-c.nix — OFFSITE-2 storage + Tailscale scraper-egress proxy.
# doc 09 §3, doc 10 Phase 2. Identical shape to node-b, different zone/IP/hostId.
{ ... }:
{
  imports = [
    ./disko-storage.nix
    # TODO operator: ./node-c-hardware.nix (generated at install)
  ];

  networking.hostName = "node-c";
  # TODO operator: unique 8-hex-digit ZFS hostId.
  networking.hostId = "deadbee3";

  fleet = {
    role = "storage";
    zone = "offsite-2";
    proxyNode = true; # carries the Tailscale scraper-egress proxy role
    # TODO operator: node-C's tailscale0 overlay IP (100.x.x.C).
    tailscaleIp = "100.64.0.12";
  };

  sops.secrets."tailscale-authkey".sopsFile = ../secrets/node-c-tailscale.sops.yaml;

  # ⚠️ Same offsite whole-box-theft boot-trust note as node-b (doc 09 §7).

  # Layout: garage layout assign <id-C> -z offsite-2 -c <bytes>  (doc 10 P2)
}
