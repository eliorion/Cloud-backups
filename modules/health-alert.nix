# modules/health-alert.nix — push an alert to the operator's phone when a node
# needs a human: dpool still locked after a reboot, garage.service down, a peer
# missing from the cluster, a degraded pool, a failing disk, or a stalled sanoid
# snapshot ladder. Without it, every one of those is found by hand — and at rf=2
# (W=2) one node down already stops every backup upload.
#
# ── STAGED behind fleet.healthAlert.enable (default FALSE), like fleet.scrapeProxy ──
# Off = no timer, no secret, no behaviour change.
#
# ── HOW IT ALERTS ──
# A oneshot `fleet-health` runs every 15 min as root (it needs `zfs`, `smartctl`
# and the garage CLI, all root-only). It ALWAYS logs its findings to the journal
# (`journalctl -u fleet-health`); when there are problems it also POSTs one
# message to an ntfy topic URL (https://ntfy.sh/<topic> or a self-hosted ntfy).
# It repeats every run until fixed — a nag, deliberately. The check itself never
# changes state: read-only commands only.
#
# ── SECRET: `ntfy_url` in secrets/common.enc.yaml (fleet-identical) ──
# A public ntfy topic name IS the credential (anyone who knows it can read the
# alerts), so the full URL lives in sops, not here. Add it BEFORE enabling — a
# missing key fails at build time, it cannot reach a node:
#     nix run .#sops -- edit secrets/common.enc.yaml    # ntfy_url: https://ntfy.sh/<long-random-topic>
#
# ── EGRESS ──
# The POST leaves via the node's own ISP uplink (outbound only, no listener, no
# firewall change). Message text carries node + check names only, no secrets.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.healthAlert;
  isStorage = config.fleet.role == "storage";
  garageBin = "${config.services.garage.package}/bin/garage";
  datasetArgs = lib.concatStringsSep " " (map lib.escapeShellArg config.fleet.sanoidDatasets);

  check = pkgs.writeShellApplication {
    name = "fleet-health";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.curl
      pkgs.systemd
    ]
    ++ lib.optionals isStorage [
      config.boot.zfs.package
      pkgs.smartmontools
    ];
    text = ''
      problems=()

      if [ "$(systemctl is-active garage.service || true)" != active ]; then
        problems+=("garage.service is not active")
      elif ! out=$(${garageBin} -c /etc/garage.toml status 2>&1); then
        problems+=("garage status failed")
      elif grep -q 'FAILED NODES' <<<"$out"; then
        problems+=("garage: peer(s) down: $(awk '/FAILED NODES/{f=1;next} f&&NF>1&&$1!="ID"{printf "%s ",$2}' <<<"$out")")
      fi

      ${lib.optionalString isStorage ''
        datasets=( ${datasetArgs} )
        for ds in "''${datasets[@]}"; do
          ks=$(zfs get -H -o value keystatus "$ds" 2>/dev/null || echo missing)
          [ "$ks" = available ] || problems+=("$ds keystatus=$ks (run: fleet unlock)")
        done

        pools=$(zpool status -x 2>&1)
        [ "$pools" = "all pools are healthy" ] || problems+=("zpool: $(head -n 3 <<<"$pools" | tr -s '\n\t' '  ')")

        while read -r dev _; do
          rc=0
          smartctl -H "$dev" >/dev/null 2>&1 || rc=$?
          # smartctl exit bit 3 (8) = SMART says the disk is failing.
          if (( rc & 8 )); then problems+=("SMART: $dev reports FAILING"); fi
        done < <(smartctl --scan)

        newest=$(zfs list -H -p -t snapshot -o creation -s creation -r "''${datasets[0]}" 2>/dev/null | tail -n 1)
        if [ -z "$newest" ] || (( $(date +%s) - newest > ${toString cfg.maxSnapshotAgeHours} * 3600 )); then
          problems+=("sanoid: no snapshot of ''${datasets[0]} in ${toString cfg.maxSnapshotAgeHours}h")
        fi
      ''}

      if (( ''${#problems[@]} == 0 )); then
        echo "ok"
        exit 0
      fi

      msg=$(printf '%s\n' "''${problems[@]}")
      echo "$msg"
      curl -fsS --max-time 20 \
        -H "Title: ${config.networking.hostName}: ''${#problems[@]} problem(s)" \
        -H "Priority: high" -H "Tags: warning" \
        -d "$msg" "$(cat "$CREDENTIALS_DIRECTORY/ntfy_url")" >/dev/null
    '';
  };
in
{
  options.fleet.healthAlert = {
    enable = lib.mkEnableOption "the 15-minute node health check that pushes problems to ntfy (see header)";

    maxSnapshotAgeHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Alert when the newest sanoid snapshot is older than this (hourly ladder → 3 tolerates one missed run).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."ntfy_url" = {
      sopsFile = ../secrets/common.enc.yaml;
      mode = "0400";
    };

    environment.systemPackages = [ check ]; # run it by hand: sudo fleet-health

    systemd.services.fleet-health = {
      description = "Fleet node health check (alerts to ntfy)";
      after = [
        "network-online.target"
        "garage.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe check;
        LoadCredential = "ntfy_url:${config.sops.secrets."ntfy_url".path}";
      };
    };

    systemd.timers.fleet-health = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min"; # give the operator time to `fleet unlock` before nagging
        OnUnitActiveSec = "15min";
      };
    };
  };
}
