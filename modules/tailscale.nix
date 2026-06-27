# modules/tailscale.nix — fleet tailnet membership (doc 09 §3/§8, doc 10
# Phase 1/2). Every Garage listener rides the tailnet only; this module joins
# the node to the tailnet, tags it tag:garage, and toggles the
# subnet-router/exit-node role for the offsite proxy nodes (B/C).
#
# The authkey comes from sops-nix (per-node file, see modules/sops.nix +
# hosts/*.nix). It is a reusable, non-ephemeral, tagged key — a CLUSTER-JOIN
# CREDENTIAL (doc 09 §8): on suspected leak, revoke + re-mint in the admin
# console.
#
# DENY-BY-DEFAULT ACL (lives in the Tailscale admin console, NOT in this repo —
# referenced here for the operator, doc 09 §3, doc 10 Phase 0):
#   - tag:garage  -> tag:garage  on tcp:3900,3901,3903   (fleet talks to itself)
#   - tag:k8s     -> tag:garage  on tcp:3900 ONLY         (prod S3, never RPC/admin)
#   The prod cluster reaching :3901 (RPC) could join the gossip cluster; reaching
#   :3903 (admin) is layout/key/bucket CONTROL, not metrics. Both are denied.
{ config, lib, ... }:
let
  cfg = config.fleet;
  # Offsite storage nodes (B/C) also carry the Tailscale scraper-egress proxy
  # role: they advertise routes / act as exit nodes (doc 09 §3, doc 10 Phase 2).
  # Set per host via fleet.proxyNode.
  isProxy = cfg.proxyNode;
in
{
  options.fleet.proxyNode = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable Tailscale subnet-router / exit-node proxy role (offsite B/C only).";
  };

  options.fleet.advertiseRoutes = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Subnet routes this proxy advertises (scraper-egress role), e.g. [\"192.168.1.0/24\"]. Approve in the Tailscale ACL.";
  };

  config = {
    services.tailscale = {
      enable = true;
      openFirewall = true; # UDP discovery port; Garage ports stay tailnet-only
      authKeyFile = config.sops.secrets."tailscale-authkey".path;

      # Subnet-router / exit-node features only on the proxy nodes (B/C). Storage
      # A and gateway D do not route for others.
      useRoutingFeatures = if isProxy then "both" else "none";

      extraUpFlags =
        [
          # Tag every fleet device tag:garage so the deny-by-default ACL applies.
          "--advertise-tags=tag:garage"
          "--ssh=false"
        ]
        ++ lib.optionals isProxy [
          "--advertise-exit-node"
        ]
        # Subnet route(s) for the scraper-egress role come from fleet.advertiseRoutes
        # (set per host). Must match the role this node carries; approve in the ACL
        # (doc 10 Phase 2). Empty list → no --advertise-routes flag emitted.
        ++ lib.optionals (isProxy && cfg.advertiseRoutes != [ ]) [
          "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}"
        ];
    };

    # IP forwarding is required for subnet-router / exit-node nodes.
    boot.kernel.sysctl = lib.mkIf isProxy {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
  };
}
