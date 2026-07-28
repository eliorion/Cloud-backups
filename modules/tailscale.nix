# modules/tailscale.nix — fleet tailnet membership (doc 00 §3/§8, doc 01
# Phase 1/2). Every Garage listener rides the tailnet only; this module joins
# the node to the tailnet, tags it tag:garage, and toggles the
# subnet-router/exit-node role for the offsite proxy nodes (B/C).
#
# The authkey comes from sops-nix (per-node file, see modules/sops.nix +
# hosts/*.nix). It is a reusable, non-ephemeral, tagged key — a CLUSTER-JOIN
# CREDENTIAL (doc 00 §8): on suspected leak, revoke + re-mint in the admin
# console.
#
# DENY-BY-DEFAULT ACL (lives in the Tailscale admin console, NOT in this repo —
# referenced here for the operator, doc 00 §3, doc 01 Phase 0):
#   - tag:garage  -> tag:garage  on tcp:3900,3901,3903   (fleet talks to itself)
#   - tag:k8s     -> tag:garage  on tcp:3900 ONLY         (prod S3, never RPC/admin)
#   The prod cluster reaching :3901 (RPC) could join the gossip cluster; reaching
#   :3903 (admin) is layout/key/bucket CONTROL, not metrics. Both are denied.
{ config, lib, ... }:
let
  cfg = config.fleet;
  # Offsite storage nodes (B/C) also carry the Tailscale scraper-egress proxy
  # role: they advertise routes / act as exit nodes (doc 00 §3, doc 01 Phase 2).
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

      # LOGIN-time flags only. The nixpkgs module runs `tailscale up` from
      # tailscaled-autoconnect.service ONLY when the backend state is NeedsLogin /
      # NeedsMachineAuth — so anything here is applied ONCE, at first join, and
      # editing it later is a silent no-op on a node that is already logged in.
      # Identity/tagging belongs here; anything that must stay declarative does not.
      extraUpFlags = [
        # Tag every fleet device tag:garage so the deny-by-default ACL applies.
        "--advertise-tags=tag:garage"
        "--ssh=false"
      ];

      # ROLE flags — these must converge on EVERY activation, not just first join,
      # or flipping fleet.proxyNode = false leaves the exit-node advertisement
      # (0.0.0.0/0 + ::/0) live in tailscaled's persisted prefs forever. The module
      # runs these via tailscaled-set.service, which is unconditional. Both flags are
      # emitted with an EXPLICIT value in both directions so the pref is declarative:
      # false/empty actively WITHDRAWS a previously advertised exit node / route.
      extraSetFlags = [
        "--advertise-exit-node=${lib.boolToString isProxy}"
        # Subnet route(s) for the scraper-egress role come from fleet.advertiseRoutes
        # (set per host); approve in the ACL (doc 01 Phase 2). Empty list → the flag
        # is still emitted with an empty value, which CLEARS any advertised route.
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
