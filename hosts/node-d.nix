# hosts/node-d.nix — GATEWAY node (capacity 0, no data). doc 09 §3, doc 10 P3.
#
# Gateway role: garage(gateway, capacity 0, NO zone) + tailscale. It does NOT
# import disko-storage and does NOT import zfs-sanoid — a gateway has no data
# pool and no snapshot moat (nothing to snapshot).
#
# ⚠️ node-D is ALREADY IN PRODUCTION (doc 10 Phase 3). The intended path is an
#    ADDITIVE reconfiguration in place — do NOT wipe it. Therefore the
#    disko-gateway.nix import below is COMMENTED OUT: only enable it for a
#    greenfield rebuild from bare metal. In-place, keep node-D's existing
#    partitioning and add only services.garage (this file's fleet.role=gateway).
#    Also isolate node-D's existing prod workload from the Garage service so a
#    prod-service compromise can't read /run/secrets/rpc_secret (doc 09 §3).
#
# ⚠️ RESIDUAL RISK (accepted for this skeleton): /run/secrets/rpc_secret is mode
#    0400 owner garage, but NOTHING here stops node-D's OTHER prod processes from
#    escalating to garage/root and reading the SHARED, cluster-admin-equivalent
#    rpc_secret. Until real isolation is implemented (run Garage under systemd
#    hardening — a dedicated unit with DynamicUser/ProtectSystem/PrivateTmp and a
#    uid the prod workload cannot assume, and verify no prod service shares the
#    garage user/group), a prod-service compromise on node-D yields CLUSTER-WIDE
#    Garage RPC trust. The moat that survives this is the ZFS layer (storage
#    nodes), unreachable via RPC; rpc_secret grants only RPC peering over
#    client-side-encrypted ciphertext on the restic/Kopia paths (doc 09 §2/§3).
#    TODO operator: implement the systemd hardening before declaring D done.
{ ... }:
{
  imports = [
    # ./disko-gateway.nix   # GREENFIELD REBUILD ONLY — do NOT enable in-place.
    # TODO operator: ./node-d-hardware.nix (existing prod hardware config)
  ];

  networking.hostName = "node-d";
  # TODO operator: unique 8-hex-digit ZFS hostId (only matters if ZFS is used).
  networking.hostId = "deadbee4";

  fleet = {
    role = "gateway"; # capacity 0, stores no partitions
    zone = null; # a gateway has NO zone (doc 10 Phase 3)
    proxyNode = false; # keeps its EXISTING prod proxy duties, set outside fleet scope
    # TODO operator: node-D's ACTUAL tailnet IP, captured in doc 10 Phase 0.
    # node-D is NOT tailscale-proxy-00's target (rsp-asp @ 100.100.98.5) — do
    # not assume a 100.100.98.D-style address.
    tailscaleIp = "100.64.0.13";
  };

  sops.secrets."tailscale-authkey".sopsFile = ../secrets/node-d-tailscale.sops.yaml;

  # Layout: garage layout assign <id-D> --gateway   (capacity 0, NO zone)
  #         garage layout apply --version <prev+1>   (doc 10 Phase 3)
}
