# modules/garage.nix — the Garage object-store service (doc 09 §5, doc 10
# Phase 1 garage.nix skeleton). Native NixOS services.garage renders garage.toml
# from `settings`. Every listener binds the node's tailscale0 overlay IP only —
# never 0.0.0.0 (doc 09 §3/§5 network rule).
#
# Two variants by config.fleet.role:
#   - "storage" (A/B/C): meta+data on the ZFS datasets, contributes capacity.
#   - "gateway" (D):     capacity 0, stores no partitions; tiny meta/data dirs
#                        still required because the binary needs the dirs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet;
  tsIp = cfg.tailscaleIp;
  isGateway = cfg.role == "gateway";

  # Gateway holds no partitions; storage nodes put meta+data on dedicated ZFS
  # datasets (disko-storage.nix). Gateway uses small local dirs (doc 10 Phase 3).
  metaDir = "/srv/garage/meta";
  dataDir = "/srv/garage/data";

  # Storage nodes may span multiple disks (e.g. NVMe ssd + HDD bulk, doc 12):
  # fleet.dataDirs = [{path,capacity}] → Garage multi-`data_dir`. null = single dir.
  dataPaths = if cfg.dataDirs != null then map (d: d.path) cfg.dataDirs else [ dataDir ];
in
{
  options.fleet.dataDirs = lib.mkOption {
    type = lib.types.nullOr (lib.types.listOf (lib.types.attrsOf lib.types.str));
    default = null;
    description = "Multi-disk Garage data_dir list [{path,capacity}]; null = single dataDir.";
  };

  config = {
    services.garage = {
      enable = true;
      # ⚠️ Pin Garage v2.3.0 (doc 10 Addressing / Phase 8). Renovate-tracked via
      #    the nixpkgs flake input; package attr name may differ by channel
      #    (garage_2 / garage_2_x). TODO operator: confirm the attr resolves on
      #    your pinned nixpkgs and adjust if needed.
      package = pkgs.garage_2;
      settings = {
        metadata_dir = metaDir;
        data_dir = if cfg.dataDirs != null then cfg.dataDirs else dataDir;
        db_engine = "lmdb"; # required default for replication_factor >= 2

        # IDENTICAL on every node or the cluster will not form (doc 09 §5).
        replication_factor = 3;
        consistency_mode = "consistent"; # read-after-write, quorum 2/2

        # Guards against non-recoverable LMDB corruption after unclean shutdown
        # (doc 09 §5 / §11).
        metadata_auto_snapshot_interval = "6h";

        # RPC / gossip — overlay IP only. rpc_public_addr MUST be the overlay IP
        # or peers cannot reach this node over the tailnet (doc 09 §5).
        #
        # ⚠️ NO brackets: fleet.tailscaleIp is the IPv4 Tailscale overlay address
        #    (100.64.0.x in the host files). Garage's Rust SocketAddr parser only
        #    accepts brackets around an IPv6 literal — "[100.64.0.10]:3901" fails
        #    to bind and Garage won't start. If (and only if) you set tailscaleIp
        #    to the Tailscale IPv6 ULA (fd7a:…), re-add brackets: "[${tsIp}]:3901".
        rpc_bind_addr = "${tsIp}:3901";
        rpc_public_addr = "${tsIp}:3901";
        rpc_secret_file = config.sops.secrets."rpc_secret".path;

        # TODO operator: list every OTHER node as pubkey@<overlay_ip>:3901 so the
        # cluster forms over the tailnet (doc 10 Phase 2). The node's own pubkey
        # is printed by `garage node id` after first boot; alternatively use
        # `garage node connect` once. Leave [] for the single-node Phase 1 bring-up.
        bootstrap_peers = [
          # "<peer-pubkey>@100.64.0.x:3901"
        ];

        s3_api = {
          # IPv4 overlay IP → no brackets (see rpc_bind_addr note above).
          api_bind_addr = "${tsIp}:3900";
          s3_region = "garage";
        };

        # admin + Prometheus /metrics share this listener. Bind overlay-only and
        # gate with tokens; the prod cluster's ACL must never reach :3903
        # (doc 09 §3/§9). Use *_file ONLY — inline tokens would render into the
        # world-readable Nix store (doc 09 §5).
        admin = {
          # IPv4 overlay IP → no brackets (see rpc_bind_addr note above).
          api_bind_addr = "${tsIp}:3903";
          admin_token_file = config.sops.secrets."admin_token".path;
          metrics_token_file = config.sops.secrets."metrics_token".path;
        };
      };
    };

    # Ensure the meta/data parent dir exists for the gateway (storage nodes get
    # the ZFS dataset mountpoints from disko-storage.nix). garage user owns them
    # but holds NO zfs allow on the datasets — the ZFS moat depends on that
    # (doc 09 §7, enforced in modules/zfs-sanoid.nix on storage nodes).
    systemd.tmpfiles.rules = lib.mkIf isGateway [
      "d ${metaDir} 0700 garage garage -"
      "d ${dataDir} 0700 garage garage -"
    ];

    # Storage nodes prompt-unlock their encrypted datasets POST-boot (doc 12), so
    # Garage must NOT start until meta + every data dir is a real mountpoint — else
    # it would write into empty unmounted dirs under the still-locked pool. The
    # gateway has no encrypted pool, so this condition is storage-only.
    systemd.services.garage.unitConfig = lib.mkIf (!isGateway) {
      ConditionPathIsMountPoint = [ metaDir ] ++ dataPaths;
    };

    # The Garage S3 region NixOS option is set above; the LAYOUT (zone /
    # capacity / --gateway) is applied imperatively with `garage layout assign`
    # / `apply --version prev+1` (doc 09 §5, doc 10 Phase 1/2/3), NOT declared
    # here — it is a versioned table the operator commits exactly once per change.
    #   storage A: -z onsite    -c <bytes>
    #   storage B: -z offsite-1 -c <bytes>
    #   storage C: -z offsite-2 -c <bytes>
    #   gateway D: --gateway              (capacity 0, NO zone)
  };
}
