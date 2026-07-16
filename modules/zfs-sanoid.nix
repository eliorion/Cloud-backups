# modules/zfs-sanoid.nix — the ransomware MOAT (doc 09 §7, doc 10 Phase 5).
# In commonModules (flake.nix) like every other fleet module; its config is a
# no-op unless `fleet.role == "storage"`, so the gateway (node-D, no data pool)
# is excluded automatically rather than by remembering not to import it.
#
# WHY THIS IS THE MOAT, not a nicety:
#   Garage has NO S3 Object Lock and NO object versioning (v2.3.0). So a stolen
#   `write`/`owner` S3 key — or root inside the prod cluster — can DeleteObject
#   across a whole bucket. Immutability therefore lives ENTIRELY at the ZFS
#   layer: sanoid takes READ-ONLY snapshots of the Garage datasets and prunes
#   them under a SEPARATE OS identity (the nixpkgs sanoid module runs as a
#   DynamicUser and zfs-allows ITSELF snapshot/destroy). The `garage` service
#   user (which holds the S3 creds) has ZERO `zfs allow` here, so no S3 identity
#   — and no tailnet identity — can reach the snapshots. To destroy history an
#   attacker would need OS root on all three storage nodes across three sites at
#   once; the geography is the defence. Recovery from a mass-delete is
#   `zfs clone` (verify) then `zfs rollback`.
#
# HARD INVARIANT (audit in doc 10 Phase 5 gate): `zfs allow bpool/garage` must
# show the garage user NOWHERE. Never `zfs allow garage …destroy/rollback`.
#
# ⚠️ NODE-A EXCEPTION — the moat above does NOT hold on node-A. It also runs the
#    workstation role (modules/workstation.nix), whose ROOT docker daemon puts the
#    `sysadmin` user one `docker run -v /:/host` away from uid 0, and therefore from
#    `zfs destroy dpool/garage@*`. Deliberate operator trade for the full container
#    envelope. The "attacker needs OS root on all three nodes at once" argument
#    therefore reduces to node-B + node-C — which is where the real defence lives,
#    and why NEITHER may take a workstation role.
{ config, lib, ... }:
{
  # Which ZFS datasets sanoid snapshots (the moat). Default bpool/garage (the
  # single-disk skeleton); doc-12 dual-disk nodes set [ "npool/garage" "dpool/garage" ].
  options.fleet.sanoidDatasets = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "bpool/garage" ];
    description = "ZFS datasets sanoid snapshots (the moat).";
  };

  # Storage-only. `options` above stays unconditional (an option must be declared
  # even where it is unused) — only `config` is gated.
  config = lib.mkIf (config.fleet.role == "storage") {
    # Native ZFS is enabled; the encrypted pool + datasets are declared in
    # disko-storage.nix. Here we add the snapshot policy + pool hygiene.
    boot.supportedFilesystems = [ "zfs" ];

    # --- sanoid: read-only snapshots, root/sanoid-pruned (NOT S3-pruned) ------
    services.sanoid = {
      enable = true;
      templates.garage = {
        # hourly + daily ladder, 30–90d retention (doc 09 §7 / doc 10 Phase 5).
        hourly = 48; # ~2 days of hourly granularity
        daily = 90; # 90 days of daily — the long-retention immutable tier
        monthly = 3;
        autosnap = true; # take snapshots
        autoprune = true; # prune per policy (root/sanoid identity only)
      };
      # Recurse so each pool's garage/meta + garage/data children are covered.
      # ⚠️ meta and data are SEPARATE datasets (and, on dual-disk nodes, separate
      #    POOLS npool/dpool) and are NOT crash-consistent together — a rollback
      #    must snapshot/roll BOTH and then `garage repair blocks` to reconcile
      #    (doc 09 §10 ransomware path).
      datasets = lib.genAttrs config.fleet.sanoidDatasets (_: {
        useTemplate = [ "garage" ];
        recursive = true;
      });
    };

    # --- pool hygiene --------------------------------------------------------
    services.zfs.autoScrub = {
      enable = true;
      interval = "weekly";
    };
    services.zfs.trim.enable = true; # SSD trim for the metadata dataset

    # NOTE: the moat depends on the garage user holding NO zfs allow on
    # bpool/garage. We deliberately declare NOTHING that grants it. If a future
    # change needs garage to self-snapshot, do it through sanoid/root — never via
    # `zfs allow garage`. (Optional hardening, doc 10 Phase 5: `zfs hold` key
    # snapshots to block destroy even by root — left to the operator.)
  };
}
