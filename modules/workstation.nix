# modules/workstation.nix — node-A's SECOND role: a remote devcontainer
# workstation co-located with the onsite DR Garage node. Driven from a Mac with
# DevPod's SSH provider: DevPod SSHes in as the `dev` user and points
# DOCKER_HOST at that user's ROOTLESS podman socket — so the Mac stays thin and
# the containers run on node-A's NVMe. Imported by hosts/node-a.nix ONLY.
#
# MOAT PRESERVATION — why rootless, why no docker group, why a plain user:
#   The ransomware moat (modules/zfs-sanoid.nix) holds only while NO routine
#   identity can `zfs destroy` the Garage snapshots. Day-to-day dev work runs
#   arbitrary code, so it must stay UNPRIVILEGED:
#     - `dev` is a normal user: NOT in wheel (no sudo), NOT in any docker/podman
#       root group, and granted NO `zfs allow` on dpool/garage anywhere.
#     - Rootless podman maps container-root → an unprivileged subuid. A container
#       escape therefore lands as `dev`, which cannot touch the root-owned ZFS
#       snapshots on the (separate, encrypted) HDD pool.
#   Only a kernel-level user-namespace escape defeats this; a root docker daemon
#   (virtualisation.docker / podman dockerCompat) would NOT — hence neither here.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # --- rootless podman: docker-compatible API for DevPod --------------------
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    # Deliberately NO dockerCompat and NO dockerSocket: both create a ROOT docker
    # socket (uid 0 daemon) and would put the moat at risk. DevPod talks to the
    # per-user ROOTLESS socket instead (DOCKER_HOST, see below).
  };

  # --- the workstation user (unprivileged; DevPod's SSH target) -------------
  users.users.dev = {
    isNormalUser = true;
    uid = 2000; # PINNED: the rootless podman socket path /run/user/2000/… is baked
    # into DOCKER_HOST (sshd block below), so the uid must be deterministic.
    home = "/home/dev"; # ZFS dataset wpool/dev (hosts/disko-node-a.nix)
    # No extraGroups on purpose — not wheel, not docker. See moat note above.
    linger = true; # keep /run/user/<uid> + the rootless podman socket alive
    # without an active login, so DevPod can (re)connect any time.
    autoSubUidGidRange = true; # /etc/subuid + /etc/subgid for rootless userns
    # Your Mac's SSH public key — DevPod connects to node-A as `dev`.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDW1Q2aJgg7HzWHshxgu2alaNuSQ4JV23PSDoP9bY1qu skh@MacBook-Air-de-samuel-3.local"
    ];
  };

  # The ZFS dataset mounts /home/dev as root:root; hand it to the dev user.
  systemd.tmpfiles.rules = [
    "d /home/dev 0700 dev users - -"
  ];

  # The dev user's rootless podman API socket (/run/user/2000/podman/podman.sock)
  # is enabled automatically by virtualisation.podman.enable — upstream already
  # sets systemd.user.sockets.podman.wantedBy = [ "sockets.target" ]. `linger`
  # above keeps it listening with no active login. No extra wiring needed.

  # --- DevPod entry: harden + wire the `dev` SSH login ----------------------
  # Rides on the sshd from modules/base.nix. DevPod's SSH provider runs the remote
  # docker CLI, which reads DOCKER_HOST — but a non-interactive SSH session sources
  # no profile, so DOCKER_HOST must be forced server-side (SetEnv + the pinned uid).
  services.openssh.extraConfig = ''
    Match User dev
      # MOAT: code running as `dev` is assumed hostile. Kill agent forwarding so a
      # key forwarded from the operator's Mac (which holds the fleet root/ops/deploy
      # keys) can NEVER be used from a dev session to SSH root@node-* and
      # `zfs destroy` the snapshots. AllowTcpForwarding stays on — DevPod tunnels.
      AllowAgentForwarding no
      X11Forwarding no
      SetEnv DOCKER_HOST=unix:///run/user/2000/podman/podman.sock
  '';

  # DevPod uses SSH ONLY — no new firewall ports. NOTE: modules/base.nix opens
  # port 22 on ALL interfaces (key-only), not just the mesh, so the `dev` login is
  # reachable on the onsite LAN too — key-only auth + `AllowAgentForwarding no`
  # (above) bound that exposure.
  #
  # SUPPORTED ENVELOPE (rootless): standard devcontainers work; `--privileged`,
  # docker-in-docker, and host ports <1024 do NOT under rootless podman.
  # fuse-overlayfs is the storage driver rootless podman uses on ZFS (a kernel
  # rootless-overlay upperdir on ZFS is unavailable); without it podman silently
  # falls back to the `vfs` driver = full per-layer copies, huge NVMe use. Verify
  # with `sudo -u dev podman info | grep -A2 graphDriver` after first boot.
  environment.systemPackages = with pkgs; [
    podman-compose
    docker-client
    fuse-overlayfs
  ];

  # --- ZFS ARC cap: 16 GB RAM is shared between dev and ZFS ------------------
  # Default ARC ≈ 50% RAM (8 GB) would starve devcontainers. Cap at 4 GiB; the
  # onsite Garage load is light. Raise if a Garage scrub/repair wants more cache.
  boot.extraModprobeConfig = "options zfs zfs_arc_max=4294967296";
}
