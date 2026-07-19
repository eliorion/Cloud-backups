# modules/garage-ops.nix — operator convenience for the manual prompt-unlock gate
# (doc 03/04). Two commands on every STORAGE node:
#
#   garage-status  — is the cluster online, and does THIS node need unlocking?
#                    Prints each encrypted dataset's keystatus + garage.service
#                    state + the `garage status` cluster view (node up/down list).
#   garage-unlock  — prompt for (or read from stdin) the ZFS passphrase, load the
#                    key on every locked encryptionroot, `zfs mount -a`, and start
#                    garage.service. Idempotent: already-unlocked datasets skipped.
#
# PRIVILEGE MODEL: these are plain scripts, NOT setuid (a setuid shell script is a
# known footgun — bash drops the elevated euid on start). They invoke the root-only
# steps through sudo, which is passwordless for `wheel` (modules/base.nix
# security.sudo.wheelNeedsPassword = false) — `sysadmin` is in wheel, so the
# operator runs `garage-unlock` and NEVER types sudo, gaining nothing beyond the
# passwordless-root wheel already has. NO `zfs allow` is granted to any user here —
# the snapshot moat (modules/zfs-sanoid.nix) depends on the garage user, and every
# non-root user, holding no destroy/rollback delegation.
#
# The encryptionroots to unlock are DERIVED from fleet.sanoidDatasets (the same
# per-node list the moat snapshots), so a node unlocks exactly the pools it owns
# (node-A: dpool/garage; node-B/-C: npool/garage + dpool/garage).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet;
  # The encrypted containers a `zfs load-key` must target = the sanoid roots.
  datasetArgs = lib.concatStringsSep " " (map lib.escapeShellArg cfg.sanoidDatasets);
  # Canonical NixOS setuid sudo (passwordless for wheel). Absolute path so the
  # scripts do not depend on /run/wrappers/bin being early in PATH.
  sudo = "/run/wrappers/bin/sudo";
  garageBin = "${config.services.garage.package}/bin/garage";

  statusScript = pkgs.writeShellApplication {
    name = "garage-status";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.systemd
    ];
    text = ''
      datasets=( ${datasetArgs} )

      echo "== ZFS encryption gate (this node) =="
      for ds in "''${datasets[@]}"; do
        ks=$(${sudo} zfs get -H -o value keystatus "$ds" 2>/dev/null || echo "MISSING")
        mnt=$(${sudo} zfs get -H -o value mounted "$ds" 2>/dev/null || echo "-")
        printf '  %-16s keystatus=%-12s mounted=%s\n' "$ds" "$ks" "$mnt"
      done

      echo
      echo "== garage.service =="
      printf '  %s\n' "$(systemctl is-active garage.service || true)"

      echo
      echo "== garage cluster status =="
      if ! ${sudo} ${garageBin} -c /etc/garage.toml status 2>&1; then
        echo "  (RPC unreachable — this node's garage is down or its pool is still locked)"
      fi
    '';
  };

  unlockScript = pkgs.writeShellApplication {
    name = "garage-unlock";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.systemd
    ];
    text = ''
      datasets=( ${datasetArgs} )

      # Passphrase: hidden prompt on a TTY, else one line from stdin (pipeable:
      # `printf '%s' "$pass" | garage-unlock`). Never taken from argv (ps-visible).
      if [ -t 0 ]; then
        read -rsp "ZFS passphrase: " pass
        echo
      else
        IFS= read -r pass || true
      fi
      if [ -z "''${pass:-}" ]; then
        echo "no passphrase given" >&2
        exit 1
      fi

      for ds in "''${datasets[@]}"; do
        ks=$(${sudo} zfs get -H -o value keystatus "$ds")
        if [ "$ks" = available ]; then
          echo "  $ds already unlocked"
        else
          printf '%s' "$pass" | ${sudo} zfs load-key "$ds"
          echo "  $ds key loaded"
        fi
      done

      ${sudo} zfs mount -a
      ${sudo} systemctl start garage.service
      echo "garage.service: $(systemctl is-active garage.service || true)"
    '';
  };
in
{
  # Storage-only: the gateway (node-D) has no encrypted data pool to unlock.
  config = lib.mkIf (cfg.role == "storage") {
    environment.systemPackages = [
      statusScript
      unlockScript
    ];
  };
}
