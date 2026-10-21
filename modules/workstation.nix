# modules/workstation.nix — node-A's SECOND role: a remote devcontainer
# workstation co-located with the onsite DR Garage node. Driven from a Mac with
# DevPod's SSH provider: DevPod SSHes in as the dedicated `devpod` user (uid 1000 —
# see the user block below for why that number is load-bearing) and talks to the
# ROOT docker daemon's /var/run/docker.sock (via the docker group) — so the Mac
# stays thin and the containers run on node-A's NVMe. Imported by hosts/node-a.nix
# ONLY. (Historical note: this was rootless podman + a DOCKER_HOST override; it is
# now a root docker daemon — see the moat trade below.)
#
# ⚠️ MOAT FORFEITED ON NODE-A — READ BEFORE TRUSTING modules/zfs-sanoid.nix:
#   This module runs a ROOT docker daemon and puts `sysadmin` in the `docker` group.
#   The docker group is root-equivalent by design: `docker run -v /:/host` yields
#   uid 0 on the host, and therefore `zfs destroy dpool/garage@*`. So on node-A the
#   ZFS snapshot moat does NOT hold against:
#     - a container escape,
#     - malicious third-party code run inside a devcontainer (a hostile npm/pip
#       transitive dep is the realistic vector — it arrives via package.json, not
#       via the network),
#     - anything that compromises the `devpod` (or `sysadmin`) session.
#   This was chosen DELIBERATELY (operator decision): node-A trades its moat for
#   --privileged / docker-in-docker / low ports. Tailscale-only exposure does NOT
#   mitigate it — the perimeter is not the threat model here.
#
#   FLEET CONSEQUENCE: node-A is the ONSITE copy. Its moat is now advisory; the
#   real ransomware defence is the OFFSITE nodes B + C, whose moats are intact and
#   which run no workstation role. Do not add a workstation role to B or C without
#   re-reading this. A ransomware event that reaches node-A's root can destroy
#   node-A's snapshot history; recovery then depends on B/C.
#
#   CHANGED vs the old `dev` user: `sysadmin` IS now in wheel (approved node-A
#   design — one operator user, [ wheel docker ]), so it also has sudo on node-A.
#   The surviving blast-radius control is sshd's AllowAgentForwarding no (below): a
#   key forwarded from the operator's Mac (which holds the fleet root/deploy keys)
#   cannot be reused from a sysadmin session to reach root@node-b / node-c and
#   `zfs destroy` THEIR snapshots. deploy-rs/nixos-anywhere use root (NOT sysadmin),
#   so this restriction costs the operator nothing. B and C staying out of reach is
#   what makes the node-A trade survivable.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # --- docker: root daemon, full envelope (replaces the rootless podman setup) --
  # See the moat note at the top of this file. DevPod/docker CLI reach the default
  # /var/run/docker.sock via the `docker` group — no DOCKER_HOST override needed.
  virtualisation.docker = {
    enable = true;
    # data-root is the ZFS dataset wpool/docker (hosts/disko-node-a.nix). The
    # native `zfs` driver creates a child dataset per layer — cheap CoW clones,
    # and it keeps images off the wpool/root system dataset. wpool already carries
    # the acltype=posixacl + xattr=sa the driver wants.
    storageDriver = "zfs";
    autoPrune = {
      enable = true; # dangling layers on a 400G pool add up fast
      dates = "weekly";
    };
  };

  # --- the workstation user's node-A-only group membership ------------------
  # `sysadmin` itself (isNormalUser, [ wheel ], uid 2000, Mac key, home
  # /home/sysadmin) is defined fleet-wide in modules/base.nix. Here — node-A ONLY,
  # where virtualisation.docker is enabled and the `docker` group therefore exists
  # — we ADD that group. List options merge across modules, so sysadmin ends up in
  # [ wheel docker ] on node-A while staying [ wheel ] on B/C/D (which have no
  # docker group; see the base.nix note). ROOT-EQUIVALENT: the docker group grants
  # full control of the root daemon — the deliberate moat trade documented at the
  # top of this file.
  users.users.sysadmin.extraGroups = [ "docker" ];

  # --- `devpod`: the devcontainer login, uid PINNED to 1000 ------------------
  # DevPod's SSH provider connects as THIS user and reaches /var/run/docker.sock
  # via the docker group. uid 1000 is load-bearing, not cosmetic: at the end of
  # every `devpod up` the agent chowns the workspace bind-mount to the CONTAINER
  # user (`vscode` = uid 1000 in the devcontainers base images). The agent itself
  # runs as this host user, so if the two uids differ it can no longer rewrite
  # ~/.devpod/.../content on the NEXT `up` — every rebuild then dies with
  # "permission denied" on .devcontainer/Dockerfile or .devpod-internal/. That is
  # exactly what `sysadmin` (uid 2000, PINNED for wpool/home ownership) hit, and
  # why devpod got its own login instead. DevPod has no option to skip the chown.
  #
  # NOT in wheel — unlike `sysadmin` this user needs no sudo on node-A (the agent
  # logs "No root required"). It IS in docker, which is root-equivalent (the moat
  # trade at the top of this file), but keeping it out of wheel means hostile code
  # in a devcontainer no longer lands directly in the fleet OPERATOR account.
  users.users.devpod = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "docker" ];
    # Same operator Mac key as sysadmin/root (see modules/base.nix).
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAATODO_operator_paste_your_ed25519_pubkey operator@workstation"
    ];
  };

  # The wpool/home ZFS dataset mounts /home/sysadmin as root:root (disko creates it
  # owned by root); hand it to the sysadmin user.
  # /home/devpod is NOT on that dataset — wpool/home mounts at /home/sysadmin
  # specifically, so devpod's workspaces (repo copies; image layers live on
  # wpool/docker) sit on wpool/root. Give it its own dataset if it ever grows.
  systemd.tmpfiles.rules = [
    "d /home/sysadmin 0700 sysadmin users - -"
    "d /home/devpod 0700 devpod users - -"
  ];

  # --- DevPod entry: harden the `devpod` + `sysadmin` SSH logins ------------
  # Rides on the sshd from modules/base.nix. No DOCKER_HOST is set: the docker CLI
  # defaults to /var/run/docker.sock, which both users reach via the docker group.
  services.openssh.extraConfig = ''
    Match User sysadmin,devpod
      # CONTAINMENT: code running as `devpod`/`sysadmin` is assumed hostile — and with the
      # docker group that means assumed root-on-node-A. Killing agent forwarding is
      # what stops it becoming root on node-B/node-C too: a key forwarded from the
      # operator's Mac (which holds the fleet root/deploy keys) must NEVER be
      # reusable from a sysadmin session to SSH root@node-* and `zfs destroy` THEIR
      # snapshots. This is the fleet's primary blast-radius control, not a nicety,
      # and it matters MORE now that sysadmin is in wheel. AllowTcpForwarding stays
      # on — DevPod tunnels.
      AllowAgentForwarding no
      X11Forwarding no
  '';

  # DevPod uses SSH ONLY — no new firewall ports. NOTE: modules/base.nix opens
  # port 22 on ALL interfaces (key-only), not just the mesh, so the `sysadmin`
  # login is reachable on the onsite LAN too — key-only auth + `AllowAgentForwarding
  # no` (above) bound that exposure.
  #
  # SUPPORTED ENVELOPE (root docker): the full one — devcontainers, `--privileged`,
  # docker-in-docker, host ports <1024. That envelope IS the reason the moat was
  # traded away (see top). Verify the storage driver is `zfs` and NOT a silent
  # fallback after first boot:
  #     docker info | grep -A2 'Storage Driver'
  environment.systemPackages = with pkgs; [
    docker-compose
    docker-client
  ];

  # --- ZFS ARC cap: 16 GB RAM is shared between dev and ZFS ------------------
  # Default ARC ≈ 50% RAM (8 GB) would starve devcontainers. Cap at 4 GiB; the
  # onsite Garage load is light. Raise if a Garage scrub/repair wants more cache.
  # zfs_vdev_scrub_max_active=1 (default 3): fewer concurrent scrub I/Os per vdev,
  # so a dpool scrub on the single HDD leaves room for garage's block reads.
  # Applied at module load (reboot); set it live with
  #     echo 1 | sudo tee /sys/module/zfs/parameters/zfs_vdev_scrub_max_active
  boot.extraModprobeConfig = "options zfs zfs_arc_max=4294967296 zfs_vdev_scrub_max_active=1";

  # --- Garage vs devcontainers: protect garage's memory ----------------------
  # Devcontainers filled RAM + swap (a tmpfs /tmp alone held 7G), evicting
  # garage's LMDB pages; every miss then waited on disk and garage's RPC stalled
  # until peers marked node-A failed (2026-10-19). MemoryLow keeps up to 2G of
  # garage's memory — page cache of its mmapped LMDB included — out of reclaim
  # while other cgroups still have something to give back. Soft: no OOM risk.
  systemd.services.garage.serviceConfig.MemoryLow = "2G";
}
