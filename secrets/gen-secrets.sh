#!/usr/bin/env bash
# garage-fleet/secrets/gen-secrets.sh
#
# Bootstraps the SEPARATE-TRUST-DOMAIN secrets for the Garage backup fleet
# (doc 09 §8, doc 10 Phase 0). It:
#   1. generates the fleet age keypair (workstation identity) if missing;
#   2. generates the shared Garage rpc_secret, admin_token, metrics_token;
#   3. prints the age RECIPIENT to paste into garage-fleet/.sops.yaml;
#   4. shows how to materialise + `sops -e` the .example templates.
#
# It does NOT write any *.enc.yaml (encrypted) file and does NOT touch the
# prod cluster's keys. Run it on your workstation, from the garage-fleet root:
#
#     ./secrets/gen-secrets.sh
#
# It is idempotent-ish: it never overwrites an existing age key, and it prints
# fresh random tokens each run (you decide whether to rotate). Break-glass:
# the fleet age PRIVATE key is catastrophic-loss material — copy it offline to
# two physical locations (doc 09 §8, doc 10 Phase 0).
set -euo pipefail

# --- locations ---------------------------------------------------------------
# Fleet age identity (workstation). Kept OUTSIDE the repo so it is never
# committed. Override with FLEET_AGE_KEY_FILE if you store it elsewhere.
AGE_KEY_FILE="${FLEET_AGE_KEY_FILE:-${HOME}/.config/sops/age/garage-fleet.txt}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 1; }; }
need age-keygen
need openssl

echo "==> garage-fleet secret bootstrap (separate trust domain — NOT prod keys)"
echo

# --- 1. fleet age keypair ----------------------------------------------------
if [[ -f "${AGE_KEY_FILE}" ]]; then
  echo "==> Fleet age key already exists: ${AGE_KEY_FILE} (leaving it untouched)"
else
  echo "==> Generating fleet age keypair -> ${AGE_KEY_FILE}"
  mkdir -p "$(dirname "${AGE_KEY_FILE}")"
  ( umask 077; age-keygen -o "${AGE_KEY_FILE}" )
  echo "    ⚠️  BREAK-GLASS: copy this private key offline to TWO physical"
  echo "        locations (paper/steel + password manager). Losing it makes"
  echo "        every fleet-encrypted secret an unreadable brick (doc 09 §8)."
fi

RECIPIENT="$(age-keygen -y "${AGE_KEY_FILE}")"
echo
echo "==> Fleet age RECIPIENT (public key). Paste this in garage-fleet/.sops.yaml"
echo "    in place of the age1FLEET… placeholder:"
echo
echo "        ${RECIPIENT}"
echo

# --- 2. shared Garage secrets ------------------------------------------------
# rpc_secret is cluster-admin-equivalent for Garage and is SHARED, identical,
# across all four nodes (doc 09 §3). admin/metrics tokens gate the admin API.
RPC_SECRET="$(openssl rand -hex 32)"
ADMIN_TOKEN="$(openssl rand -hex 32)"
METRICS_TOKEN="$(openssl rand -hex 32)"
# ZFS dataset passphrase for bpool/garage (storage nodes). Persisted via the
# sops-nix `zfs-passphrase` secret so the node reboot-unlocks without the /tmp
# install seed (hosts/disko-storage.nix). Catastrophic-loss break-glass item.
ZFS_PASSPHRASE="$(openssl rand -base64 32)"

echo "==> Generated shared Garage secrets. Put them in common.enc.yaml:"
echo
echo "        rpc_secret     = ${RPC_SECRET}"
echo "        admin_token    = ${ADMIN_TOKEN}"
echo "        metrics_token  = ${METRICS_TOKEN}"
echo "        zfs-passphrase = ${ZFS_PASSPHRASE}"
echo "    ⚠️  zfs-passphrase is BREAK-GLASS + catastrophic-loss: keep an offline"
echo "        copy in two physical locations (doc 09 §8)."
echo

# --- 3. how to encrypt the templates ----------------------------------------
cat <<EOF
==> Next steps (encrypt the templates into real sops files):

  # a) Make sure garage-fleet/.sops.yaml has the recipient above (and, after
  #    provisioning each node, that node's ssh-to-age recipient too), then:
  export SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}"

  # b) Shared secrets — copy the template, fill the values printed above:
  cp "${SCRIPT_DIR}/common.enc.yaml.example" "${SCRIPT_DIR}/common.enc.yaml"
  \$EDITOR "${SCRIPT_DIR}/common.enc.yaml"        # paste rpc/admin/metrics/zfs-passphrase
  sops -e -i "${SCRIPT_DIR}/common.enc.yaml"       # encrypt in place

  # c) Per-node Tailscale auth key (mint a reusable, non-ephemeral, tagged key
  #    in the Tailscale admin console with tag:garage — doc 09 §8, doc 10 P0):
  for n in node-a node-b node-c node-d; do
    cp "${SCRIPT_DIR}/node.enc.yaml.example" "${SCRIPT_DIR}/\${n}.enc.yaml"
    \$EDITOR "${SCRIPT_DIR}/\${n}.enc.yaml" # paste tskey-auth-…
    sops -e -i "${SCRIPT_DIR}/\${n}.enc.yaml"
  done

  # d) Verify a node can decrypt (after adding its recipient + re-encrypting):
  sops -d "${SCRIPT_DIR}/common.enc.yaml" >/dev/null && echo "decrypt OK"

==> Reminder: ZFS dataset passphrase + restic/Kopia/age repo passwords are also
    break-glass items (doc 09 §8). The ZFS key is seeded at install via
    nixos-anywhere --disk-encryption-keys; keep an offline copy regardless.
EOF
