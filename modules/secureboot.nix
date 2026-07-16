# modules/secureboot.nix — node-A ONLY. Secure Boot (lanzaboote signed UKIs) +
# systemd stage-1 initrd + TPM2 auto-unlock of the `cryptwork` LUKS container.
#
# ROLE IN THE TWO-TRUST-DOMAIN DESIGN:
#   TPM-AUTO domain  = NVMe p3 LUKS2 `cryptwork` -> zpool `wpool` (root, sysadmin
#     home, docker; swap is a SEPARATE randomEncryption partition). Unlocks
#     UNATTENDED at boot from the TPM, no console/network. Protects ONLY against a
#     powered-OFF media theft.
#   MANUAL-GATE domain = HDD `dpool/garage` (ZFS-native, keylocation=prompt),
#     unlocked post-boot over the mesh with `zfs load-key`. NOT handled here.
#
# WHY systemd stage-1 is MANDATORY (not optional):
#   systemd-cryptenroll's TPM2 keyslot is a LUKS2 `systemd-tpm2` *token*. Only
#   systemd-cryptsetup (the systemd initrd) can read that token; the legacy
#   scripted stage-1 cannot. So boot.initrd.systemd.enable = true is required for
#   the TPM-auto story, and it gives the correct unlock ORDERING:
#     TPM -> systemd-cryptsetup@cryptwork (initrd) -> /dev/mapper/cryptwork
#       -> zfs-import-wpool (initrd, wpool is a rootPool) -> wpool/root = /sysroot
#       -> switch-root -> stage-2 activation -> sops-nix decrypts (needs the SSH
#          host key that lives on wpool/root) -> tailscale authkey present -> mesh.
#   wpool MUST be unlocked+mounted in initrd, BEFORE activation, or sops-nix
#   cannot decrypt and the node never rejoins the mesh (chicken-and-egg).
#   These initrd bits are UNCONDITIONAL (not gated on fleet.secureBoot): the TPM
#   LUKS unlock works under plain systemd-boot too, and it is what boots the box
#   through the whole pre-Secure-Boot bootstrap below.
#
# ─────────────────────────────────────────────────────────────────────────────
# ON-BOX ENROLLMENT RUNBOOK (run ONCE, at the console, after the first install)
# ─────────────────────────────────────────────────────────────────────────────
# STAGED because lanzaboote's activation hook signs every UKI with keys under
# /var/lib/sbctl that do NOT exist until step 3. `fleet.secureBoot` (base.nix)
# stays FALSE through the install AND the first deploy so those run under
# systemd-boot; you flip it true only once the keys exist. Get the ORDER right —
# each step's precondition is the previous step's output, and two orderings are
# load-bearing (marked ⚠).
#
#  1. INSTALL with fleet.secureBoot = false (the default). `fleet install node-a
#     root@host` formats the disks; cryptwork LUKS keyslot 0 = the LUKS install
#     passphrase (scripts/fleet prompts for it; keep it in the break-glass vault —
#     it is the ONLY recovery once the TPM is sealed).
#
#  2. FIRST BOOT is at the CONSOLE. There is no TPM2 token yet, so
#     systemd-cryptsetup falls back to a passphrase prompt — type the LUKS install
#     passphrase within ~60 s of the prompt (the initrd ZFS root-import has a ~60 s
#     patience window; be at the keyboard before powering on). systemd-boot, no
#     Secure Boot yet. Do the first `fleet deploy node-a` now (still SB-off) to get
#     a deploy-rs rollback baseline.
#
#  3. GENERATE this machine's Secure Boot key hierarchy (PK/KEK/db):
#         sudo sbctl create-keys          # writes /var/lib/sbctl (== pkiBundle)
#
#  4. ⚠ SIGN THE UKIs BEFORE enabling Secure Boot. Flip fleet.secureBoot = true in
#     hosts/node-a.nix, commit, and `fleet deploy node-a`. This activates
#     lanzaboote: every UKI on the ESP is now signed with the step-3 db key and
#     systemd-boot is gone. Confirm before touching firmware:
#         sudo sbctl verify               # every *.efi under the ESP: signed
#     (Secure Boot is still OFF in firmware, so the signed UKI still boots normally.
#     Enabling SB before this step would leave nothing signed for firmware to
#     verify — an unbootable box.)
#
#  5. ENROLL keys + turn Secure Boot ON. Reboot into the firmware, put it in Setup
#     Mode (clear/delete the Platform Key), confirm, enroll (keep Microsoft's UEFI
#     CA so signed option-ROM firmware still loads), enable Secure Boot, and SET A
#     FIRMWARE SUPERVISOR PASSWORD:
#         sudo sbctl status               # Setup Mode: Enabled
#         sudo sbctl enroll-keys --microsoft
#     then in the UEFI menu enable Secure Boot + set the supervisor password. The
#     password stops a thief re-entering setup mode to enroll THEIR keys / disable
#     SB / reorder boot to sidestep the signed UKI.
#
#  6. Boot NixOS (still the console LUKS passphrase — no TPM token yet). Confirm SB
#     is truly active and our UKIs verify:
#         sudo sbctl status               # Secure Boot: Enabled, Setup Mode: Disabled
#         bootctl status | grep -i secure
#
#  7. ⚠ SEAL THE TPM ONLY NOW — PCR 7 must already reflect the final "Secure Boot
#     ON, our keys" state, or the next boot's PCR 7 will not match and the TPM
#     refuses. You are asked for an EXISTING passphrase to authorize the new
#     keyslot — type the LUKS install passphrase:
#         sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
#             /dev/disk/by-partlabel/disk-nvme-cryptwork
#
#  8. Reboot. cryptwork must now unlock UNATTENDED (no prompt) via the TPM token.
#     Confirm the install passphrase survived as a recovery keyslot (cryptenroll
#     only ADDS a keyslot):
#         sudo cryptsetup luksDump /dev/disk/by-partlabel/disk-nvme-cryptwork
#     Expect BOTH keyslot 0 (passphrase) AND a `systemd-tpm2` token. Keep that
#     passphrase — it is the ONLY way back after a firmware/dbx update rotates
#     PCR 7 (see §PCR7). It is a DIFFERENT secret from the dpool ZFS passphrase.
#
# ─── WHY PCR 7 (and not 0–9) ─────────────────────────────────────────────────
# PCR 7 measures the Secure Boot policy: on/off state + PK/KEK/db/dbx + the
# CERTIFICATE that signed the currently-loaded EFI binary. It does NOT measure the
# binary's hash. So every deploy-rs push signs a NEW UKI with the SAME db key ->
# PCR 7 unchanged -> the TPM keeps releasing the key across kernel/initrd/cmdline
# updates. That is the whole point on a node reconfigured often by deploy-rs.
#   Tamper protection does NOT come from measuring the kernel — it comes from
# lanzaboote: the kernel cmdline (init=, root=) is baked INTO the signed UKI, and
# under Secure Boot systemd-stub ignores any loader-appended cmdline. A thief
# cannot boot init=/bin/sh without re-signing, which needs our db.key. PCR 7
# guarantees the LUKS key is released ONLY when Secure Boot is on with OUR keys.
#   PCR 0/2/3 break on every BIOS update; PCR 4/8/9 (image/cmdline/initrd hash)
# change on EVERY lanzaboote rebuild -> the TPM would stop unlocking after each
# deploy. PCR 7 is the only one both meaningful AND stable under our update model.
# Its one moving part — a firmware/dbx revocation rotating PCR 7 — is exactly what
# the recovery passphrase keyslot is for.
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
let
  sb = config.fleet.secureBoot;
in
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  # --- Secure Boot: signed UKIs, STAGED on fleet.secureBoot -------------------
  # Gate BOTH bootloader backends on the same flag, inverted, so there is always
  # exactly one: sb=false -> base.nix's systemd-boot (mkDefault true) stands;
  # sb=true -> systemd-boot forced off and lanzaboote on. Enabling lanzaboote
  # before /etc/secureboot exists (install / first deploy) bricks the box — see
  # the runbook. mkForce beats base.nix's mkDefault.
  boot.loader.systemd-boot.enable = lib.mkIf sb (lib.mkForce false);

  boot.lanzaboote = lib.mkIf sb {
    enable = true;
    # PKI from `sbctl create-keys` (runbook §3). sbctl 0.17 in this nixpkgs stores
    # keys under /var/lib/sbctl (the /etc/secureboot default was dropped in sbctl
    # 0.14); lanzaboote reads ${pkiBundle}/keys/db/db.{pem,key}.
    pkiBundle = "/var/lib/sbctl";
    # Enroll BY HAND (runbook §5) to keep Microsoft's UEFI CA and control the
    # firmware trip. enrollKeys=true would auto-run a bricking-risk enroll on deploy.
    enrollKeys = false;
    # LOCK THE BOOT PATH: disable the loader's line editor so a console thief cannot
    # append init=/bin/sh. (Under Secure Boot systemd-stub already ignores
    # loader-appended cmdline; this closes the UI too.) configurationLimit is left
    # to inherit boot.loader.systemd-boot.configurationLimit (base.nix = 10).
    settings.editor = false;
  };

  # --- systemd stage-1 initrd + TPM2 (UNCONDITIONAL — see header) -------------
  # Required for the systemd-tpm2 LUKS token and the correct unlock ordering, and
  # it is what unlocks cryptwork through the whole SB-off bootstrap. tpm2.enable
  # defaults true via systemd.package.withTpm2Units (pulls tpm-tis/tpm-crb + the
  # systemd-tpm2 cryptsetup plugin); set explicitly so an upstream regression can't
  # silently drop TPM support on this node.
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.tpm2.enable = true;

  # NOTE: the `tpm2-device=auto` crypttab option for cryptwork is set by disko
  # (hosts/disko-node-a.nix settings.crypttabExtraOpts), which merges into
  # boot.initrd.luks.devices.cryptwork. Do NOT also set it here — listOf options
  # concatenate, producing a duplicate token. disko owns the LUKS device, so the
  # crypttab option lives with it.

  # On-box tooling for the runbook (sbctl). cryptsetup + systemd-cryptenroll are
  # already in the base system. Present regardless of `sb` so create-keys/enroll
  # work during the SB-off bootstrap.
  environment.systemPackages = [ pkgs.sbctl ];
}
