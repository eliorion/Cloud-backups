# modules/base.nix — host hardening shared by every fleet node (doc 00 ADR-2,
# doc 01 Phase 1 "hardening.nix"). SSH hardening, nftables firewall trusting
# only the tailnet + ssh, users, bounded boot generations, flakes, no
# auto-upgrade (atomic deploys come from deploy-rs, doc 00 ADR-4).
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.fleet = {
    # This node's tailscale0 overlay IP. services.tailscale does NOT export the
    # assigned 100.x address at eval time, so Garage's listeners (modules/
    # garage.nix) must read it from here — set per host in hosts/*.nix
    # (doc 01 Phase 1 garage.nix skeleton note).
    tailscaleIp = lib.mkOption {
      type = lib.types.str;
      example = "100.64.0.10";
      description = "This node's tailscale0 overlay IP (TODO operator per host).";
    };

    zone = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [
        "onsite"
        "offsite-1"
        "offsite-2"
      ]);
      default = null;
      description = "Garage replication zone label; null for the gateway (node-D has NO zone).";
    };

    role = lib.mkOption {
      type = lib.types.enum [
        "storage"
        "gateway"
      ];
      description = "storage = holds data + ZFS pool + sanoid; gateway = capacity 0, no data pool.";
    };

    # true  = auto-unlock the encrypted data pool from a sops-persisted passphrase
    #         at boot (onsite convenience; weaker whole-box-theft story).
    # false = prompt-unlock post-boot via `zfs load-key` (offsite default, doc 03).
    # Gates the sops `zfs-passphrase` secret (modules/sops.nix) and which unlock
    # path hosts/disko-node-*.nix wires. See documentations/04 Phase 0.
    zfsAutoUnlock = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "true = auto-unlock data pool from a sops passphrase at boot; false = prompt-unlock post-boot (offsite default).";
    };

    # INSTALL-ONLY. null at runtime → encrypted ZFS datasets use keylocation
    # "prompt" (the moat). The flake's `<node>-install` variant sets this to a
    # tmpfs path; nixos-anywhere uploads the passphrase there via
    # --disk-encryption-keys so disko can format the encrypted pools
    # non-interactively on a remote installer (no TTY for a prompt). scripts/fleet
    # restores keylocation=prompt right after first boot (`zfs set keylocation`),
    # so the seed file never persists and the passphrase is never stored on the
    # box. Harmless on unencrypted nodes (no encrypted dataset references it).
    zfsInstallKeyfile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/tmp/fleet-zfs.key";
      description = "Install-only tmpfs path the ZFS passphrase is uploaded to (nixos-anywhere --disk-encryption-keys); null at runtime = keylocation=prompt.";
    };

    # Install-only tmpfs path for the cryptwork LUKS passphrase (node-A's TPM-auto
    # root domain). SET by hosts/disko-node-a.nix in the `-install` variant, so
    # scripts/fleet can detect that this node needs a SECOND --disk-encryption-keys
    # pair (a DIFFERENT passphrase from the dpool ZFS one — the LUKS keyslot-0 is the
    # TPM recovery secret). null on runtime configs and on every non-LUKS node.
    luksInstallKeyfile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/tmp/fleet-luks.key";
      description = "Install-only tmpfs path the cryptwork LUKS passphrase is uploaded to; null at runtime and on non-LUKS nodes (node-A only).";
    };

    # STAGED bootstrap flag for lanzaboote Secure Boot (node-A, modules/secureboot.nix).
    # MUST stay false through BOTH `fleet install` AND the first `fleet deploy`:
    # lanzaboote's activation hook signs every UKI with /etc/secureboot/keys, which do
    # NOT exist until the on-box `sbctl create-keys` step — enabling it earlier makes
    # nixos-install/switch fail after the disks are already wiped (unbootable box).
    # The operator flips this true in hosts/node-a.nix ONLY after create-keys, then
    # deploys (signs UKIs) → enrolls keys + enables Secure Boot in firmware → seals the
    # TPM. See the runbook in modules/secureboot.nix. false = systemd-boot (unsigned).
    secureBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "node-A only: true = lanzaboote signed-UKI Secure Boot; false = systemd-boot. Keep false until sbctl keys exist on the box (see modules/secureboot.nix runbook).";
    };
  };

  config = {
    # --- nix / flakes --------------------------------------------------------
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Storage/gateway boxes have no other tenants; keep the build sandbox on.
      sandbox = true;
      trusted-users = [
        "root"
        "@wheel"
      ];
    };
    # No automatic upgrades — convergence is an explicit, atomic `deploy-rs`
    # push with magic-rollback (doc 00 ADR-4). Drift/auto-reboots would defeat
    # the OS-as-code property.
    system.autoUpgrade.enable = false;
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    # --- bounded boot generations (atomic rollback target set) ---------------
    boot.loader.systemd-boot.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
    boot.loader.systemd-boot.configurationLimit = 10;

    # --- users ---------------------------------------------------------------
    # Key-only admin user. Password login is disabled fleet-wide (see sshd).
    users.mutableUsers = false;
    # `sysadmin` is the fleet's single human operator user (was `ops`). On node-A
    # it doubles as the devcontainer host user — modules/workstation.nix ADDS the
    # `docker` group there, so sysadmin ends up in [ wheel docker ] on node-A and
    # [ wheel ] on B/C/D. `docker` is NOT listed here on purpose: the group only
    # exists where virtualisation.docker is enabled (node-A); putting it here would
    # name a group absent on B/C/D. (extraGroups referencing a missing group is
    # silently ignored — users-groups.nix only asserts on the PRIMARY group — but
    # it would mislead a reader; list options merge, so workstation.nix is the
    # right place for the node-A-only membership.)
    users.users.sysadmin = {
      isNormalUser = true;
      uid = 2000; # PINNED: deterministic ownership of node-A's wpool/home ZFS
      # dataset across rebuilds (hosts/disko-node-a.nix). Harmless on B/C/D.
      extraGroups = [ "wheel" ];
      # Operator break-glass + interactive/DevPod key (Mac). NOTE: on node-A this
      # user's SSH login sets AllowAgentForwarding no (modules/workstation.nix);
      # deploy-rs/nixos-anywhere use root, not this user.
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDW1Q2aJgg7HzWHshxgu2alaNuSQ4JV23PSDoP9bY1qu skh@MacBook-Air-de-samuel-3.local"
      ];
    };
    # root login over ssh is key-only too (see sshd); used by deploy-rs/
    # nixos-anywhere. Same operator Mac key (deploy/break-glass).
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDW1Q2aJgg7HzWHshxgu2alaNuSQ4JV23PSDoP9bY1qu skh@MacBook-Air-de-samuel-3.local"
    ];
    # CONSOLE rescue only — this does NOT weaken ssh, which stays key-only
    # (PasswordAuthentication=false below). Without it, mutableUsers=false leaves
    # root locked and sulogin unusable, so any boot that fails before sshd is
    # recoverable ONLY with physical install media. See modules/sops.nix for why
    # the secret must be neededForUsers. It lives in the PER-NODE file, so each
    # node has its own root password; a missing key is caught at BUILD time.
    users.users.root.hashedPasswordFile = config.sops.secrets."root_password_hash".path;
    security.sudo.wheelNeedsPassword = false;

    # --- openssh: key only, no passwords -------------------------------------
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password"; # key-only root for deploy-rs
      };
      # The host key is the node's SSH SERVER identity only. It is NOT the sops
      # identity — that is a DEDICATED age key at /var/lib/sops-nix/key.txt
      # (modules/sops.nix age.keyFile) — so it can be regenerated freely. NixOS
      # generates this ed25519 key on first boot if absent; `fleet install` does
      # NOT pre-seed it (only the age key is seeded). A reinstall therefore mints a
      # fresh host key, so clear the stale known_hosts entry (ssh-keygen -R <host>).
      hostKeys = [
        {
          type = "ed25519";
          path = "/etc/ssh/ssh_host_ed25519_key";
        }
      ];
    };

    # --- firewall: nftables, tailnet + ssh only ------------------------------
    # Every Garage listener binds tailscale0 only (modules/garage.nix); the
    # firewall trusting only tailscale0 is the host-side half of the network
    # isolation moat layer (doc 00 §3/§7). Binding 0.0.0.0 with a loose firewall
    # would expose S3 beyond the tailnet and defeat the whole moat.
    networking.nftables.enable = true;
    networking.firewall = {
      enable = true;
      trustedInterfaces = [ "tailscale0" ];
      # ssh on the physical NIC is the break-glass / nixos-anywhere path only;
      # everything else (S3/RPC/admin 3900/3901/3903) is tailnet-only and thus
      # covered by trustedInterfaces above, NOT opened here.
      allowedTCPPorts = [ 22 ];
      # Tailscale's own UDP discovery port is handled by services.tailscale
      # (modules/tailscale.nix sets openFirewall).
    };

    # --- misc ----------------------------------------------------------------
    time.timeZone = lib.mkDefault "UTC";
    i18n.defaultLocale = "en_US.UTF-8";
    environment.systemPackages = with pkgs; [
      vim
      curl
      jq
    ];

    # TODO operator: set to the channel you locked in flake.nix at first install
    # and DO NOT bump casually (state-version semantics).
    system.stateVersion = "25.05";
  };
}
