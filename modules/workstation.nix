# modules/workstation.nix — node-A's SECOND role: a remote devcontainer
# workstation co-located with the onsite DR Garage node. Driven from a Mac with
# DevPod's SSH provider: DevPod SSHes in as the `dev` user and points
# DOCKER_HOST at that user's ROOTLESS podman socket — so the Mac stays thin and
# the containers run on node-A's NVMe. Imported by hosts/node-a.nix ONLY.
#
# ⚠️ MOAT FORFEITED ON NODE-A — READ BEFORE TRUSTING modules/zfs-sanoid.nix:
#   This module runs a ROOT docker daemon and puts `dev` in the `docker` group.
#   The docker group is root-equivalent by design: `docker run -v /:/host` yields
#   uid 0 on the host, and therefore `zfs destroy dpool/garage@*`. So on node-A the
#   ZFS snapshot moat does NOT hold against:
#     - a container escape,
#     - malicious third-party code run inside a devcontainer (a hostile npm/pip
#       transitive dep is the realistic vector — it arrives via package.json, not
#       via the network),
#     - anything that compromises the `dev` session.
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
#   Still true, and worth keeping: `dev` is NOT in wheel, and sshd sets
#   AllowAgentForwarding no (below) so a forwarded key cannot be reused to reach
#   root@node-b / node-c from a compromised dev session. That containment — B and C
#   staying out of reach — is what makes the node-A trade survivable.
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
    # and it keeps images off the 60G ext4 root. wpool already carries the
    # acltype=posixacl + xattr=sa the driver wants.
    storageDriver = "zfs";
    autoPrune = {
      enable = true; # dangling layers on a 400G pool add up fast
      dates = "weekly";
    };
  };

  # --- the workstation user (unprivileged; DevPod's SSH target) -------------
  users.users.dev = {
    isNormalUser = true;
    uid = 2000; # PINNED: deterministic ownership of /home/dev on the ZFS dataset
    # across rebuilds. (No longer load-bearing for a socket path — the rootless
    # podman socket it used to encode is gone.)
    home = "/home/dev"; # ZFS dataset wpool/dev (hosts/disko-node-a.nix)
    # ROOT-EQUIVALENT: the docker group grants full control of the root daemon.
    # This is the deliberate trade documented at the top of this file. NOT wheel —
    # that at least keeps `sudo` off the table for non-container paths.
    extraGroups = [ "docker" ];
    # Your Mac's SSH public key — DevPod connects to node-A as `dev`.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDW1Q2aJgg7HzWHshxgu2alaNuSQ4JV23PSDoP9bY1qu skh@MacBook-Air-de-samuel-3.local"
    ];
  };

  # The ZFS dataset mounts /home/dev as root:root; hand it to the dev user.
  systemd.tmpfiles.rules = [
    "d /home/dev 0700 dev users - -"
  ];

  # --- DevPod entry: harden the `dev` SSH login -----------------------------
  # Rides on the sshd from modules/base.nix. No DOCKER_HOST is set: the docker CLI
  # defaults to /var/run/docker.sock, which `dev` can reach via the docker group.
  services.openssh.extraConfig = ''
    Match User dev
      # CONTAINMENT: code running as `dev` is assumed hostile — and with the docker
      # group that now means assumed root-on-node-A. Killing agent forwarding is
      # what stops it becoming root on node-B/node-C too: a key forwarded from the
      # operator's Mac (which holds the fleet root/ops/deploy keys) must NEVER be
      # reusable from a dev session to SSH root@node-* and `zfs destroy` THEIR
      # snapshots. This is now the fleet's primary blast-radius control, not a
      # nicety. AllowTcpForwarding stays on — DevPod tunnels.
      AllowAgentForwarding no
      X11Forwarding no
  '';

  # DevPod uses SSH ONLY — no new firewall ports. NOTE: modules/base.nix opens
  # port 22 on ALL interfaces (key-only), not just the mesh, so the `dev` login is
  # reachable on the onsite LAN too — key-only auth + `AllowAgentForwarding no`
  # (above) bound that exposure.
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
  boot.extraModprobeConfig = "options zfs zfs_arc_max=4294967296";
}
