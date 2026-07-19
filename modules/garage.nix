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

  # Every OTHER node this node should gossip to, as "<pubkey>@<overlay_ip>:3901"
  # (the `garage node id` output of each peer). Declarative + persistent, so the
  # cluster re-forms over the tailnet after any reboot without a manual `garage
  # node connect`. Empty = single-node bring-up. Set per host in hosts/*.nix.
  options.fleet.bootstrapPeers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "aef46cd1…@100.64.0.10:3901" ];
    description = "Other nodes' <pubkey>@<overlay_ip>:3901 for Garage bootstrap_peers (cluster gossip over the tailnet).";
  };

  config = {
    services.garage = {
      enable = true;
      # ⚠️ Design target is v2.3.0 (doc 10 Addressing / Phase 8), but nixpkgs
      #    nixos-25.05 ships NO garage_2_3_0 attr — the newest is garage_2_1_0, so
      #    this resolves to 2.1.0 and 2.1.0 is what deploys. Verify with:
      #      nix eval --raw .#nixosConfigurations.node-a.config.services.garage.package.version
      #    To actually get 2.3.0, bump the nixpkgs input to a channel carrying it or
      #    add an overlay — see documentations/13-node-a-b-install.md. Renovate
      #    tracks the nixpkgs input. Both versions lack Object Lock / S3 versioning,
      #    so the ZFS moat argument is unaffected either way.
      package = pkgs.garage_2;
      settings = {
        metadata_dir = metaDir;
        data_dir = if cfg.dataDirs != null then cfg.dataDirs else dataDir;
        db_engine = "lmdb"; # required default for replication_factor >= 2

        # IDENTICAL on every node or the cluster will not form (doc 09 §5). This is
        # a SINGLE cluster-wide number, NOT additive per node. Phase 1 = node-A
        # alone, so 1 (one copy; Garage serves with a single node). To get a copy on
        # each of A/B/C, raise to 3 on ALL nodes at once AFTER B+C join, redeploy the
        # fleet, then re-push the DR data — cheap here (re-pushable from prod, pool
        # ~empty now). rf=3 CANNOT apply with < 3 nodes: the layout needs 3 distinct
        # nodes to place 3 copies, so it stays 1 until B and C exist.
        replication_factor = 1;
        consistency_mode = "consistent"; # rf=1 → quorum 1/1 (at rf=3 → 2/3)

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

        # Every OTHER node as pubkey@<overlay_ip>:3901 so the cluster forms over the
        # tailnet (doc 10 Phase 2). Set per host via fleet.bootstrapPeers (each
        # peer's `garage node id`). Empty = single-node bring-up.
        bootstrap_peers = cfg.bootstrapPeers;

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

    # STATIC garage system user/group. nixpkgs runs services.garage as a systemd
    # DynamicUser (no persistent user), but modules/sops.nix owns the garage
    # secrets (rpc_secret/admin/metrics) `owner = "garage"` — so sops-nix's manifest
    # validation aborts "unknown user garage" and NO secrets render (starving both
    # garage and tailscale). A stable user also gives the ZFS data dirs a real
    # owner. NO `zfs allow` is granted here — the snapshot moat depends on the
    # garage user having none (doc 09 §7, modules/zfs-sanoid.nix).
    users.groups.garage = { };
    users.users.garage = {
      isSystemUser = true;
      group = "garage";
      home = metaDir;
      createHome = false;
    };

    # Ensure the meta/data parent dir exists for the gateway (storage nodes get
    # the ZFS dataset mountpoints from disko-storage.nix).
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

    # Upstream's garage unit sets NO Restart=, so any crash — notably an OOM kill on
    # node-B's 4 GB box — leaves Garage down until a human notices, on nodes that are
    # offsite by design. Restart it.
    #
    # Safe against the ConditionPathIsMountPoint above: a failed condition makes
    # systemd SKIP the unit (not fail it), so a still-locked pool cannot drive a
    # restart loop. RestartSec covers a pool that mounts moments later.
    systemd.services.garage.serviceConfig = {
      # Run as the static garage user (above), NOT a DynamicUser — see the user
      # block for why (sops secrets are owner=garage). mkForce beats the nixpkgs
      # module's DynamicUser=true default.
      DynamicUser = lib.mkForce false;
      User = "garage";
      Group = "garage";
      # meta+data are ZFS mountpoints created root-owned (disko), and on storage
      # nodes they mount only after the post-boot manual unlock — so chown them to
      # garage right before start. ConditionPathIsMountPoint guarantees they are
      # mounted by now; the leading '+' runs this as root, not as garage.
      ExecStartPre = [
        "+${pkgs.coreutils}/bin/chown garage:garage ${metaDir} ${lib.concatStringsSep " " dataPaths}"
      ];
      Restart = "on-failure";
      RestartSec = "10s";
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
