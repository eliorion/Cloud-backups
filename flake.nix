{
  # garage-fleet — standalone NixOS fleet for the geo-distributed Garage backup
  # cluster (documentations/09 §3, ADR-1/-2/-4; documentations/10 Phase 0/1).
  #
  # This is a SEPARATE TRUST DOMAIN from the prod Talos cluster: different OS
  # (NixOS, not Talos), different identities (its own sops-nix age keys, NOT the
  # cluster PKI), different network posture, no shared etcd (doc 09 §2). It is
  # NOT joined to prod and is NOT a second Kubernetes cluster (ADR-1).
  #
  # Deployed via deploy-rs (NOT Flux). deploy-rs is chosen over colmena for its
  # MAGIC ROLLBACK (ADR-4): a bad tailscaled/firewall change on a remote offsite
  # node auto-reverts within ~30s instead of stranding a node you cannot reach.
  #
  # ⚠️ flake.lock IS committed and must stay tracked — a flake's source is its
  #    git-tracked files, so a gitignored lock is invisible to nix and every input
  #    silently floats to upstream HEAD. See README.
  description = "Garage backup fleet — standalone NixOS + ZFS (doc 09/10)";

  inputs = {
    # Pinned to a stable channel (25.05-era). Renovate/operator bumps this; the
    # exact rev is resolved into flake.lock by the operator's `nix flake lock`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Provisioning tool, NOT part of any host closure — `scripts/fleet install`
    # runs it as `nix run .#nixos-anywhere`, so flake.lock pins the exact rev
    # instead of the bare `github:` ref floating on every install.
    # No `inputs.nixpkgs.follows`: unlike disko/sops-nix/deploy-rs this never
    # enters a nixosConfiguration, so there is nothing to dedup, and pinning it
    # to our 25.05 nixpkgs only risks breaking the tool's own build.
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";

    # Secure Boot: signed Unified Kernel Images. node-A ONLY (its module is
    # imported per-host, not in commonModules) — B/C/D keep systemd-boot until
    # each has had its own firmware key-enrollment trip. Pinned; Renovate-tracked.
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      disko,
      sops-nix,
      deploy-rs,
      nixos-anywhere,
      lanzaboote,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # Modules every host shares. Per-host disko + hardware are added in
      # hosts/*.nix. Modules here self-gate on `fleet.role` (garage.nix branches
      # storage/gateway; zfs-sanoid.nix is storage-only) rather than being
      # imported by hand per host.
      commonModules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./modules/base.nix
        ./modules/sops.nix
        ./modules/tailscale.nix
        ./modules/garage.nix
        ./modules/zfs-sanoid.nix
      ];

      # THE source of truth for the fleet's nodes. `scripts/fleet` adds ONE line
      # here when it scaffolds a new node; nixosConfigurations + the deploy map
      # below are DERIVED from this, so a new node needs no other flake edit.
      hosts = {
        node-a = ./hosts/node-a.nix;
        node-b = ./hosts/node-b.nix;
        node-c = ./hosts/node-c.nix;
        # node-d is ALREADY IN PRODUCTION and reconfigured ADDITIVELY (doc 10
        # Phase 3): hosts/node-d.nix imports no disko and has no hardware-config
        # yet, so it defines no root fileSystem and would make `nix flake check`
        # fail. Re-enable it here once its real hardware-config is wired (uncomment
        # the imports in hosts/node-d.nix); `scripts/fleet` then manages it too.
        # node-d = ./hosts/node-d.nix;
      };

      # MagicDNS tailnet for the deploy-rs targetHosts. TODO operator
      # (`scripts/fleet config tailnet <name>`): replace <tailnet>.
      tailnet = "tail45b0ca";

      # Install-only tmpfs keyfile (see modules/base.nix `fleet.zfsInstallKeyfile`).
      # The `<node>-install` variants set it so nixos-anywhere can format the
      # encrypted ZFS pools non-interactively; runtime configs keep prompt-unlock.
      installKeyfile = "/tmp/fleet-zfs.key";

      mkSystem =
        modules:
        lib.nixosSystem {
          inherit system;
          # specialArgs passes the flake inputs to modules so a per-host module
          # (modules/secureboot.nix on node-A) can import an input's nixosModule
          # (inputs.lanzaboote.nixosModules.lanzaboote) without wiring it here.
          specialArgs = { inherit inputs; };
          modules = commonModules ++ modules;
        };
    in
    {
      # node-X       = runtime config, deployed by deploy-rs (keylocation=prompt).
      # node-X-install = same + a tmpfs ZFS keyfile path, used ONCE by the remote
      #                  nixos-anywhere format (`scripts/fleet install`); restored
      #                  to prompt-unlock right after first boot.
      #
      # ⚠️ magic-rollback only protects you once a PRIOR generation was also
      #    deployed by deploy-rs. The first push after nixos-anywhere has no canary
      #    baseline — do that first reachable-config deploy with console /
      #    initrd-SSH fallback available (ADR-4 caveat a, doc 10 P1).
      nixosConfigurations =
        lib.mapAttrs (_name: mod: mkSystem [ mod ]) hosts
        // lib.concatMapAttrs (name: mod: {
          "${name}-install" = mkSystem [
            mod
            { fleet.zfsInstallKeyfile = installKeyfile; }
          ];
        }) hosts;

      # deploy-rs node map, derived from `hosts`. targetHost is the Tailscale
      # MagicDNS name; per-host SSH identities go in the operator's ~/.ssh/config
      # keyed by MagicDNS name (ADR-4 caveat b: neither deploy-rs nor colmena
      # handle per-host/passphrase keys themselves).
      deploy = {
        magicRollback = true;
        autoRollback = true;
        sshUser = "root";
        user = "root";

        nodes = lib.mapAttrs (name: _mod: {
          hostname = "${name}.${tailnet}.ts.net";
          profiles.system.path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${name};
        }) hosts;
      };

      # Tools `scripts/fleet` shells out to, re-exported so it can call them as
      # `nix run .#<tool>` — resolved through flake.lock instead of a bare
      # `github:` ref that floats to upstream HEAD on every invocation. The tools
      # that format disks and push closures must not move under you.
      packages.${system} = {
        nixos-anywhere = nixos-anywhere.packages.${system}.default;
        deploy-rs = deploy-rs.packages.${system}.default;
        disko = disko.packages.${system}.disko;
        # From OUR pinned nixpkgs. `nix run nixpkgs#ssh-to-age` would instead hit
        # the flake REGISTRY (nixos-unstable), floating independently of this lock.
        ssh-to-age = pkgs.ssh-to-age;
      };

      # Operator toolchain for `scripts/fleet`, pinned by flake.lock so every
      # workstation gets identical versions: `nix develop`. Mirrors the script's
      # own dependency list (scripts/fleet header): sops/age/ssh-to-age/openssl/
      # ssh-keygen/git for `new`+`secrets`, deploy-rs + nixos-anywhere for
      # `deploy`/`install`.
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.sops
          pkgs.age
          pkgs.ssh-to-age
          pkgs.openssl
          pkgs.openssh
          pkgs.git
          deploy-rs.packages.${system}.default
          nixos-anywhere.packages.${system}.default
        ];
      };

      # `nix flake check` runs deploy-rs's own schema checks against ./deploy.
      # deployChecks returns a FLAT attrset of derivations, so it must be nested
      # under the system key (checks.<system>.<name>) to actually run.
      checks.${system} = deploy-rs.lib.${system}.deployChecks self.deploy;
    };
}
