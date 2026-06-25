# modules/sops.nix — sops-nix wiring for the fleet (doc 09 §8, doc 10 Phase 1).
#
# Each node's age identity is DERIVED from its Ed25519 SSH host key via
# ssh-to-age (sshKeyPaths below), so there is no separate age key file to seed
# or lose on the node. The host key itself is seeded at install via
# nixos-anywhere --extra-files; its ssh-to-age recipient must be added to
# garage-fleet/.sops.yaml and the secrets RE-ENCRYPTED before the first deploy,
# or activation cannot decrypt and `switch` fails (doc 09 §8 bootstrap note).
#
# Secrets are decrypted at activation into /run/secrets/<name>, owned by their
# consuming service, with restartUnits wired so rotation restarts the unit.
{ config, lib, ... }:
{
  sops = {
    # Derive the node's age key from its SSH host key (ssh-to-age). No standalone
    # /var/lib/sops-nix/key.txt to manage; the on-disk host key IS the identity.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    age.generateKey = false;

    # --- shared cluster secrets (secrets/common.sops.yaml) -------------------
    # The .example ships placeholders; the operator encrypts the real file with
    # gen-secrets.sh. Garage reads these via *_file keys (modules/garage.nix).
    secrets."rpc_secret" = {
      sopsFile = ../secrets/common.sops.yaml;
      owner = "garage";
      group = "garage";
      mode = "0400";
      restartUnits = [ "garage.service" ];
    };
    secrets."admin_token" = {
      sopsFile = ../secrets/common.sops.yaml;
      owner = "garage";
      group = "garage";
      mode = "0400";
      restartUnits = [ "garage.service" ];
    };
    secrets."metrics_token" = {
      sopsFile = ../secrets/common.sops.yaml;
      owner = "garage";
      group = "garage";
      mode = "0400";
      restartUnits = [ "garage.service" ];
    };

    # --- ZFS dataset passphrase (bpool/garage) — STORAGE nodes only -----------
    # This is what makes the documented "passphrase persisted via sops-nix per
    # node, auto-unlock at boot" model (doc 09 §7, doc 10 secrets inventory) real:
    # WITHOUT a persisted secret the node cannot `zfs load-key` after the first
    # reboot, because /tmp/zfs.key (the install seed) is gone. Declared here so it
    # lives ENCRYPTED-AT-REST under sops-nix, not as a plaintext key in /tmp.
    #
    # ⚠️ catastrophic-loss + break-glass (doc 09 §8): the passphrase is decryptable
    #    only by this node's age key (derived from its on-disk SSH host key), so a
    #    lost node fleet = unrecoverable raw-send vault unless an OFFLINE copy
    #    exists in two physical locations. Owner root, mode 0400 — never garage.
    #
    # The gateway (node-D) has no encrypted data pool, so this secret is gated to
    # storage nodes via the role check; node-D never references it.
    secrets."zfs-passphrase" = lib.mkIf (config.fleet.role == "storage") {
      sopsFile = ../secrets/common.sops.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
      # TODO operator: wire the boot-time `zfs load-key` to read THIS path
      #   (config.sops.secrets."zfs-passphrase".path) — see disko-storage.nix.
      #   sops-nix decrypts into /run/secrets after stage-2; for early-boot ZFS
      #   import either use a key-load systemd unit ordered after sops-nix, or
      #   neededForUsers/initrd secret materialisation. Do NOT leave the live key
      #   at file:///tmp/zfs.key (install seed only).
    };

    # --- per-node Tailscale auth key (secrets/<node>-tailscale.sops.yaml) -----
    # sopsFile is set PER HOST in hosts/*.nix (each node has its own file), so
    # only the path-independent bits live here.
    secrets."tailscale-authkey" = {
      key = "authkey";
      mode = "0400";
      # consumed by tailscaled at first up; no restartUnits (re-auth is manual).
    };
  };
}
