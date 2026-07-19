# 05 — node-A secure install → deploy pipeline (LUKS + TPM + Secure Boot)

The single ordered runbook for taking **node-A** from bare metal to a fully
hardened, unattended-booting, encrypted onsite storage + workstation node. Every
step says **what** you run and **why** it matters for security. node-A is the
only node with an encrypted root + Secure Boot; node-B/node-C use the simpler
prompt-unlock flow in [doc 04](04-node-a-b-install.md).

> This doc is the *pipeline narrative*. The authoritative, terse enrollment steps
> live next to the code in [`modules/secureboot.nix`](../modules/secureboot.nix);
> this doc frames them in order with the reasoning. Where the two ever disagree,
> `secureboot.nix` wins.

> **STATUS (2026-07):** node-A is installed, deployed, and healthy — LUKS/TPM boot,
> both pools ONLINE, `garage.service` active, tailscale up. Two hard-won corrections
> are folded into the steps below:
>
> - **sops/age MUST be the flake's `-tags=purego` builds** (`mise run sops`,
>   `nix run .#sops`/`.#age`, or `nix develop`) — NEVER a stock/mise binary. This
>   workstation is x86_64 under **Rosetta on Apple Silicon**, and Rosetta
>   mis-translates Go's asm ChaCha20-Poly1305, so a stock sops silently emits
>   corrupt ciphertext the node can't decrypt (`sops-install-secrets`: `0 successful
>   groups`). The nodes' own AMD CPUs are fine; only the emulated workstation is
>   affected. `scripts/fleet`/`mise.toml`/`gen-secrets.sh` already route through the
>   safe builds.
> - **Node identity is a DEDICATED age key** (`private-keys/node-a-age.txt` →
>   `/var/lib/sops-nix/key.txt`), NOT ssh-to-age of the SSH host key. `fleet new`
>   mints it, `fleet install` seeds it via `--extra-files`.

---

## 0. The picture — two trust domains on one box

```
NVMe /dev/nvme0n1
  ESP  2G  vfat  /boot                         plaintext, Secure-Boot-VERIFIED (signed UKIs)
  swap 8G        randomEncryption               fresh key per boot
  cryptwork 100% LUKS2 → zpool wpool            ── TPM-AUTO domain ──
       wpool/root   → /               (30G reservation)
       wpool/home   → /home/sysadmin  (200G reservation)
       wpool/docker → /var/lib/docker (150G quota)

HDD /dev/sda
  dpool  whole   ZFS-native aes-256-gcm         ── MANUAL gate ──
       dpool/garage/meta → /srv/garage/meta
       dpool/garage/data → /srv/garage/data-hdd
```

- **TPM-AUTO domain** (teal): unlocks itself in the initrd from a TPM2 keyslot
  sealed to PCR 7. No console, no network. After enrollment, a bare reboot brings
  up root + home + docker, the SSH host key, sops, and tailscale **unattended**.
  It protects **only** against a powered-OFF disk theft.
- **MANUAL gate** (purple): all of Garage. `keylocation=prompt`; stays ciphertext
  until you `zfs load-key dpool/garage` over the mesh. This is the **only** thing
  that ever waits for you, and the only thing a thief of a *powered-on* box can't
  read.

---

## 1. The security model — what each layer defends, and what it doesn't

| Layer | Defends against | Does NOT defend against |
|---|---|---|
| **LUKS2 + TPM (PCR 7)** on cryptwork | root/home/docker read from a **powered-off** stolen disk | a **powered-on** stolen box (TPM releases the key) |
| **lanzaboote signed UKIs + Secure Boot** | a thief editing the kernel cmdline (`init=/bin/sh`) to get a shell on decrypted root | a firmware-level attacker with the supervisor password |
| **ZFS-native `dpool` (manual gate)** | the **backups** — ciphertext even on a powered-on stolen box | nothing, once you've typed the passphrase over the mesh |
| **tailnet-only firewall** (nftables) | S3/RPC/admin reachable off the mesh | someone already on the tailnet (deny-by-default ACL handles that) |
| **per-node DEDICATED age key** (`private-keys/<node>-age.txt` → `/var/lib/sops-nix/key.txt`) | one node's compromise decrypting another's secrets | that node's own secrets |

**The two theft scenarios, concretely:**

- **Disk / media theft** (the NVMe pulled and read in another machine, or a
  failed disk RMA'd): the TPM is soldered to node-A's board and stays behind, and
  no other machine reproduces node-A's PCR 7, so the TPM key is unreachable. Root
  is LUKS-ciphertext, dpool is ZFS-ciphertext. **Nothing readable.**
- **Whole-box theft** (the realistic worst case — the thief has the box *and* its
  TPM, found off or running): powering it on *does* unseal root — it is the same
  board with our Secure Boot keys, so PCR 7 matches and the TPM releases the LUKS
  key. Two things still hold the line:
  - **Getting to that decrypted root is still gated:** no login credential is on
    the box, Secure Boot + the firmware supervisor password block booting other
    media, and the lanzaboote-locked cmdline blocks `init=/bin/sh`. The realistic
    extraction is a cold-boot/hardware attack, not a walk-up.
  - **dpool stays ciphertext regardless** — its passphrase is only in your
    head/KeePass, never on the box. So even a thief who *does* reach root gets the
    node's age key (`/var/lib/sops-nix/key.txt`) → the **tailscale authkey** (revoke
    it) and the **root password hash** (uncrackable) — but **never the backups.**
    You rotate one authkey.

This is why the ZFS passphrase must **never** be stored in sops or on disk (it is
the one secret whole-box theft cannot yield), and why the LUKS passphrase is a
*recovery* secret, not a routine one.

---

## 2. Before you start (Phase 0 — workstation + physical)

Run `./scripts/fleet status` — node-A's row should show `key ✓ recip ✓ authkey ✓
commit ✓`. If not, `fleet new node-a` first.

**Two passphrases, both in your password manager, decided now:**

| Secret | Used | If lost |
|---|---|---|
| **ZFS (dpool)** | typed over the mesh at every unlock (the manual gate) | the backups on this node are unrecoverable |
| **LUKS (cryptwork)** | keyslot 0 = the TPM **recovery** key; typed at the console when a firmware/kernel update rotates PCR 7 | you cannot boot node-A after a PCR change; a reinstall is the only way back |

Make them **different** — different domains, different rotation, different
exposure. `fleet install` will prompt for both.

**Physical access:** node-A is onsite, so this is fine — but you *need* a monitor
+ keyboard on it. The first boot and the whole Secure-Boot/TPM enrollment
(Phases 3–4) cannot be done over SSH.

**State check:** `hosts/node-a.nix` must have `fleet.secureBoot` **unset (=false)**
at this point. That is what keeps the install and the first deploy on
systemd-boot — enabling lanzaboote before its signing keys exist bricks the
install after the disks are already wiped.

---

## 3. Phase 1 — Install (nixos-anywhere, Secure Boot OFF)

```bash
SSH_PASS=root ./scripts/fleet install node-a root@192.168.1.22 -- --env-password
```

What happens, in order:

1. **Pre-wipe guards** (before anything is destroyed): the node's DEDICATED age key
   (`private-keys/node-a-age.txt`, seeded to `/var/lib/sops-nix/key.txt`) must have a
   recipient matching what the secrets are encrypted to (else the node could never
   decrypt them after install → no mesh → no unlock). fleet also confirms `lsblk`
   device paths and that secrets are committed.
2. **Two passphrase prompts:**
   - *ZFS (dpool) passphrase* → uploaded to the installer's RAM at
     `/tmp/fleet-zfs.key`, used by disko to format `dpool/garage`, then
     `keylocation` is restored to `prompt` — never written to disk.
   - *LUKS (root) passphrase* → uploaded to `/tmp/fleet-luks.key`, becomes
     cryptwork **keyslot 0**. This is a *second* `--disk-encryption-keys` pair,
     added only for LUKS-root nodes.
     - ⚠️ **Security:** this is why the two-secret feed exists. If fleet fed only
       one key, disko would format keyslot 0 with an **empty** passphrase —
       anyone with the disk could unlock root, and you'd be locked out at the
       console. Both keyslots must be seeded at format time.
3. **disko destroys both disks** and lays out the layout in §0. nixos-anywhere
   installs `.#node-a-install`, which is **systemd-boot** (lanzaboote off) because
   `fleet.secureBoot` is false.
4. The box reboots into the installed system.

**Result:** an encrypted node-A running systemd-boot, no TPM token yet, no Secure
Boot.

---

## 4. Phase 2 — First boot (console) + finalize + baseline deploy

The first boot is **at the console**, because the TPM is not enrolled yet:

1. **Console LUKS prompt.** systemd-cryptsetup finds no TPM2 token and falls back
   to a passphrase prompt. **Be at the keyboard** and type the LUKS passphrase
   **within ~60 s** (the initrd ZFS-root import has a ~60 s patience window).
2. wpool unlocks → `wpool/root` mounts as `/` → stage-2 activation → sops-nix
   decrypts (using the dedicated age key at `/var/lib/sops-nix/key.txt`, now on the
   unlocked root) → the tailscale authkey is present → **node-A joins the mesh on
   its own.** This chain is why root *must* be in the TPM/LUKS domain and unlocked
   in initrd: sops needs its age key before activation.
3. **Finalize the dpool** (fleet offers this over SSH once sshd is up, or run
   `fleet finalize node-a root@<ip>`): restores `keylocation=prompt`, then
   `zfs load-key dpool/garage && zfs mount -a` (you re-type the **ZFS**
   passphrase). Garage's `ConditionPathIsMountPoint` clears and it starts.
4. **First deploy, still SB-off** — establishes a deploy-rs rollback baseline:
   ```bash
   ./scripts/fleet deploy node-a
   ```
   ⚠️ magic-rollback can't protect this first push (no prior generation) — keep
   the console reachable.

**Result:** node-A is up on the mesh, Garage running, one manual unlock done.
Still systemd-boot / no TPM.

---

## 5. Phase 3 — Secure Boot enrollment (console + firmware)

Now stage in Secure Boot. **The ordering here is load-bearing** — sign the UKIs
*before* turning Secure Boot on, or firmware has nothing valid to verify.

1. **Generate this box's Secure Boot keys** (on node-A):
   ```bash
   sudo sbctl create-keys        # writes /etc/secureboot (== lanzaboote pkiBundle)
   ```
2. **Sign the UKIs** — flip the flag and deploy:
   ```bash
   # in hosts/node-a.nix:  fleet.secureBoot = true;
   git commit -am 'node-a: enable Secure Boot' && ./scripts/fleet deploy node-a
   sudo sbctl verify             # every *.efi under the ESP: signed
   ```
   This activates lanzaboote: every UKI is now signed with the keyslot from step
   1, and systemd-boot is gone. Secure Boot is still **off** in firmware, so the
   signed UKI still boots normally.
   - ⚠️ **Do NOT enable Secure Boot before this deploy.** With Secure Boot on and
     nothing signed, firmware rejects the boot → unbootable until you re-enter
     firmware to disable it.
3. **Enroll keys + enable Secure Boot** (reboot into firmware):
   - Put the firmware in **Setup Mode** (clear/delete the Platform Key). Confirm
     from the OS: `sudo sbctl status` → `Setup Mode: Enabled`.
   - Enroll our keys, keeping Microsoft's UEFI CA (so signed option-ROM firmware
     still loads — dropping it can brick some boards):
     ```bash
     sudo sbctl enroll-keys --microsoft
     ```
   - In the UEFI menu: **enable Secure Boot** and **set a firmware supervisor
     (admin) password.**
     - ⚠️ **Security:** the supervisor password is not decoration. Without it a
       thief can re-enter setup mode, enroll *their* keys, disable Secure Boot,
       or reorder boot to sidestep the signed UKI. It closes the tamper path that
       PCR 7 only *detects*.
4. **Boot and confirm** (still the console LUKS passphrase — no TPM yet):
   ```bash
   sudo sbctl status             # Secure Boot: Enabled, Setup Mode: Disabled
   bootctl status | grep -i secure
   ```

**Why this buys tamper-resistance:** the kernel cmdline (`init=`, `root=`) is
baked *inside* the signed UKI, and under Secure Boot systemd-stub ignores any
loader-appended cmdline. A thief can't boot `init=/bin/sh` without re-signing,
which needs your `db.key`. So "power it on and drop to a root shell on the
decrypted disk" stops working.

---

## 6. Phase 4 — Seal the TPM (console)

Only now, with Secure Boot **on and stable**, bind the LUKS key to the TPM:

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
    /dev/disk/by-partlabel/disk-nvme-cryptwork
# type the LUKS install passphrase to authorize the new keyslot
sudo reboot
```

- ⚠️ **Order is load-bearing:** seal *after* Secure Boot is on. PCR 7 measures the
  Secure Boot state + keys; if you sealed while SB was off, the next boot's PCR 7
  wouldn't match and the TPM would refuse to release the key.
- **Why PCR 7 (not 0–9):** PCR 7 measures the Secure Boot *policy* (on/off + our
  keys + the signing certificate), **not** the kernel/initrd hash. So every future
  deploy-rs push signs a *new* UKI with the *same* key → PCR 7 is unchanged → the
  TPM keeps unlocking across kernel/cmdline updates. PCR 4/8/9 would change on
  every rebuild and break unattended boot.

**Confirm the recovery keyslot survived** (cryptenroll only *adds* a keyslot):

```bash
sudo cryptsetup luksDump /dev/disk/by-partlabel/disk-nvme-cryptwork
# expect BOTH: keyslot 0 (your LUKS passphrase) AND a systemd-tpm2 token
```

**Result:** the reboot unlocks cryptwork **unattended** from the TPM — no
passphrase prompt. node-A now boots to a mesh-joined, Garage-ready state with the
*only* manual step being the dpool unlock.

---

## 7. Phase 5 — Steady state + Garage layout

**Every routine reboot** now:

1. TPM auto-unlocks root/home/docker (unattended, no console, no network).
2. tailscale rejoins the mesh on its own.
3. You SSH in over the mesh and run the one manual step:
   ```bash
   ssh sysadmin@node-a 'sudo zfs load-key dpool/garage && sudo zfs mount -a'
   # Garage starts once its mountpoints are real
   ```

**Garage layout — once, ever** (version = previous + 1):

```bash
ID=$(sudo garage node id -q | cut -d@ -f1)
sudo garage layout assign "$ID" -z onsite -c <bytes>
sudo garage layout apply --version <prev+1>
```

**Config changes** go through deploy-rs (`fleet deploy node-a`) with
magic-rollback. Because PCR 7 is stable, kernel/initrd/cmdline changes keep the
TPM unlock working — no re-enrollment needed.

**Lean on RF=3:** a node sitting "up but dpool-sealed" (you haven't unlocked it
yet) is a *degraded* state, not an outage — the other two zones hold quorum. Keep
a CNPG replica off node-A so a sealed node is never a database outage.

---

## 8. Recovery — when the TPM stops unlocking

A firmware update, a dbx (revocation) push via fwupd, or occasionally a Secure
Boot key change rotates PCR 7. The TPM then refuses, and the boot falls back to
the **console LUKS passphrase prompt** — this is exactly what keyslot 0 (your
LUKS recovery passphrase) is for.

```bash
# at the console: type the LUKS recovery passphrase, boot completes.
# then re-seal to the NEW PCR 7:
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/disk-nvme-cryptwork
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
    /dev/disk/by-partlabel/disk-nvme-cryptwork
sudo reboot        # unattended again
```

If you ever lose the LUKS recovery passphrase *and* PCR 7 has rotated, there is
**no way in** — reinstall. That is the cost of the security, and why the
passphrase belongs in two places offline.

---

## 9. Load-bearing ordering — the three things you must not reorder

1. **`fleet.secureBoot` stays false for install + the first deploy.** lanzaboote
   signs UKIs with keys that don't exist until Phase 3 step 1 → enabling it
   earlier fails the install/deploy *after* the disks are wiped.
2. **Sign the UKIs (Phase 3 step 2) BEFORE enabling Secure Boot (step 3).**
   Enabling SB with nothing signed = firmware rejects the boot.
3. **Seal the TPM (Phase 4) AFTER Secure Boot is on (Phase 3).** PCR 7 must
   already reflect the final "SB on, our keys" state, or the TPM won't match on
   the next boot.

Each is enforced or flagged in code: the flag gate in `modules/base.nix` +
`modules/secureboot.nix` (rule 1), and the `⚠` steps in the `secureboot.nix`
runbook (rules 2–3).

---

## Appendix — the two secrets, one more time

| | ZFS (dpool) passphrase | LUKS (cryptwork) passphrase |
|---|---|---|
| Protects | Garage backups (the manual gate) | root/home/docker at rest |
| Typed | every unlock, over the mesh | only at the console, on TPM-recovery |
| Stored | KeePass + one offline copy — **never** on disk or in sops | KeePass + one offline copy |
| Lost → | this node's backups unrecoverable | can't boot after a PCR change → reinstall |

node-B and node-C have only the **ZFS** one: their root is unencrypted ext4, so
there is no LUKS domain and no recovery secret. The passphrase count equals the
number of encryption domains that need a human-held secret — see
[doc 04 § Why node-A has 2 passphrases](04-node-a-b-install.md#why-node-a-has-2-passphrases-and-node-bc-have-1).
