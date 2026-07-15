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
let
  # Two files per node, by design (.sops.yaml encrypts them to different recipients):
  #   common.enc.yaml   — identical on every node, encrypted to ALL nodes
  #   <hostname>.enc.yaml — THIS node only, encrypted to this node + workstation
  # Derived from hostName rather than wired per host, so a new node needs no
  # sops.nix edit: `fleet new <node>` drops in the file and the .sops.yaml rule.
  commonSecrets = ../secrets/common.enc.yaml;
  nodeSecrets = ../secrets + "/${config.networking.hostName}.enc.yaml";
in
{
  sops = {
    # Derive the node's age key from its SSH host key (ssh-to-age). No standalone
    # /var/lib/sops-nix/key.txt to manage; the on-disk host key IS the identity.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    age.generateKey = false;

    # --- console rescue: root's password hash (PER NODE) ----------------------
    # modules/base.nix sets users.mutableUsers = false and no root password, which
    # makes root a LOCKED account: if a node ever reaches emergency.target, sulogin
    # refuses every login ("root account is locked") and the only way in is physical
    # media. node-A hit exactly that (see hosts/disko-node-a.nix noauto note).
    #
    # Lives in the PER-NODE file: each node gets its own root password, so a
    # console credential recovered from one node does not open the other three.
    #
    # neededForUsers is REQUIRED and not decorative: it stages this secret in the
    # early activation phase that runs BEFORE update-users-groups.pl writes
    # /etc/shadow. A normal secret is materialised too late and root stays locked.
    # Such secrets cannot take owner/group (users do not exist yet) — mode only.
    #
    # `root_password_hash` must exist in secrets/<node>.enc.yaml. sops-nix
    # validates the manifest at BUILD time, so a missing key fails `nix flake
    # check` / `fleet install` outright — it cannot reach a node and brick it.
    # Add one per node (each node gets its OWN password):
    #      nix develop -c openssl passwd -6           # copy the $6$… hash
    #      nix develop -c sops edit secrets/node-a.enc.yaml
    secrets."root_password_hash" = {
      sopsFile = nodeSecrets;
      neededForUsers = true;
    };

    # --- shared cluster secrets (secrets/common.enc.yaml) --------------------
    # The .example ships placeholders; the operator encrypts the real file with
    # gen-secrets.sh. Garage reads these via *_file keys (modules/garage.nix).
    secrets."rpc_secret" = {
      sopsFile = commonSecrets;
      owner = "garage";
      group = "garage";
      mode = "0400";
      restartUnits = [ "garage.service" ];
    };
    secrets."admin_token" = {
      sopsFile = commonSecrets;
      owner = "garage";
      group = "garage";
      mode = "0400";
      restartUnits = [ "garage.service" ];
    };
    secrets."metrics_token" = {
      sopsFile = commonSecrets;
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
    # The gateway (node-D) has no encrypted data pool; storage nodes that PROMPT-
    # unlock (fleet.zfsAutoUnlock = false, the offsite default — doc 12/13) also
    # persist NO passphrase on the box. So this secret exists ONLY when
    # fleet.zfsAutoUnlock = true (auto-unlock at boot from sops). node-D and every
    # prompt-unlock node never reference it.
    secrets."zfs-passphrase" = lib.mkIf config.fleet.zfsAutoUnlock {
      sopsFile = nodeSecrets;
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

    # --- per-node Tailscale auth key (secrets/<node>.enc.yaml) ----------------
    # sopsFile is DERIVED from hostName (nodeSecrets above) — it used to be wired
    # by hand in each hosts/*.nix. `key` remaps the YAML field: the file stores it
    # as `authkey`, sops-nix exposes it as tailscale-authkey.
    secrets."tailscale-authkey" = {
      sopsFile = nodeSecrets;
      key = "authkey";
      mode = "0400";
      # consumed by tailscaled at first up; no restartUnits (re-auth is manual).
    };
  };
}
