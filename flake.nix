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
  # ⚠️ NO flake.lock is committed and nix is NOT available in this environment.
  #    The OPERATOR must run `nix flake lock` once on a workstation with nix
  #    (flakes enabled) before the first `nix flake check` / deploy. See README.
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
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
      deploy-rs,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      # Modules every host shares. Per-host disko + role are added in hosts/*.nix.
      commonModules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./modules/base.nix
        ./modules/sops.nix
        ./modules/tailscale.nix
        ./modules/garage.nix
      ];

      mkHost =
        hostModule:
        lib.nixosSystem {
          inherit system;
          modules = commonModules ++ [ hostModule ];
        };
    in
    {
      nixosConfigurations = {
        node-a = mkHost ./hosts/node-a.nix;
        node-b = mkHost ./hosts/node-b.nix;
        node-c = mkHost ./hosts/node-c.nix;
        node-d = mkHost ./hosts/node-d.nix;
      };

      # deploy-rs node map. targetHost is the Tailscale MagicDNS name — set per
      # host below. deploy-rs + per-host SSH identities are configured in the
      # operator's ~/.ssh/config keyed by MagicDNS name (ADR-4 caveat b: neither
      # deploy-rs nor colmena handle per-host/passphrase keys themselves).
      #
      # ⚠️ magic-rollback only protects you once a PRIOR generation was also
      #    deployed by deploy-rs. The first push after nixos-anywhere has no
      #    canary baseline — do that first reachable-config deploy with
      #    console / initrd-SSH fallback available (ADR-4 caveat a, doc 10 P1).
      deploy = {
        magicRollback = true;
        autoRollback = true;
        sshUser = "root";
        user = "root";

        nodes =
          let
            mkNode = name: hostname: {
              inherit hostname;
              profiles.system = {
                path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${name};
              };
            };
          in
          {
            # TODO operator: replace <tailnet> with your MagicDNS tailnet name.
            node-a = mkNode "node-a" "node-a.<tailnet>.ts.net";
            node-b = mkNode "node-b" "node-b.<tailnet>.ts.net";
            node-c = mkNode "node-c" "node-c.<tailnet>.ts.net";
            node-d = mkNode "node-d" "node-d.<tailnet>.ts.net";
          };
      };

      # `nix flake check` runs deploy-rs's own schema checks against ./deploy.
      checks = deploy-rs.lib.${system}.deployChecks self.deploy;
    };
}
