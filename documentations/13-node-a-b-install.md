# 13 — node-A + node-B install runbook (dual-disk; node-A LUKS/TPM root, node-B prompt-unlock)

> **CORRECTIONS (2026-07) — these supersede the body where they conflict:**
> - **sops/age = the flake's `-tags=purego` builds ONLY** (`mise run sops`,
>   `nix run .#sops`/`.#age`, `nix develop`). This workstation is x86_64 under
>   **Rosetta on Apple Silicon**, which mis-translates Go's asm ChaCha20-Poly1305, so
>   a stock/mise sops silently emits corrupt ciphertext the nodes can't decrypt.
>   `scripts/fleet` already routes through the safe builds — prefer it over raw sops.
> - **Node identity is a DEDICATED age key** (`private-keys/<node>-age.txt` →
>   `/var/lib/sops-nix/key.txt`), **not** ssh-to-age of the SSH host key. `fleet new`
>   mints it and writes the recipient to `.sops.yaml`; `fleet install` seeds it. Any
>   `ssh-to-age`/`age-keygen`/`sops` step below is handled by `scripts/fleet` now.
> - node-A is already installed, deployed, and healthy (garage running).

The single, ordered, copy-paste runbook for installing the **first two** fleet
nodes from bare metal to a running Garage cluster:

- **node-A** — zone `onsite`, storage **+ dev workstation** (Phase 1,
  `modules/workstation.nix`). *No prior install doc existed; this fills that gap.*
- **node-B** — zone `offsite-1`, storage **+** Tailscale scraper-egress proxy.
  Detailed mechanics already in **doc 12**; here node-B is installed as the node
  that **joins node-A's cluster** (layout v2), not as a standalone single node.

**Chosen design (locked):** each box formats **two disks** and `nixos-install`s the
flake — the preferred path is **remote** (`fleet install`, nixos-anywhere), with the
live-USB flow below as the fallback.

- **node-B** = NVMe `npool` (encrypted Garage SSD) + HDD `dpool`, both
  **prompt-unlock** ZFS-native; root is **unencrypted ext4** so it boots unattended,
  then you unlock the data pools over the mesh. **ONE** human-held passphrase (the
  ZFS data).
- **node-A differs** — it is ALSO a dev workstation (`modules/workstation.nix`) *and*
  its root is encrypted. Two trust domains on one box:
  - **TPM-AUTO** (NVMe): ESP + swap + a LUKS2 `cryptwork` container (unsealed in
    initrd by a TPM2 keyslot bound to **PCR 7**) → ZFS-root `wpool` = `{root(/),
    sysadmin home, docker}`. After the one-time TPM enrollment, reboots unlock root
    **unattended** (no console, no network) — so sshd + tailscale come up on their
    own. Secure Boot via **lanzaboote** signed UKIs (`modules/secureboot.nix`) locks
    the boot path so a thief can't edit the kernel cmdline to a root shell.
  - **MANUAL GATE** (HDD `dpool`, ZFS-native, `keylocation=prompt`): **all** of
    Garage. Ciphertext until you `zfs load-key dpool/garage` over the mesh — the only
    manual step after a bare reboot.
  So node-A has **TWO** human-held secrets (see [Why node-A has 2 passphrases](#why-node-a-has-2-passphrases-and-node-bc-have-1)); node-B/C have one.

This **supersedes** the single-disk auto-unlock skeleton
(`hosts/disko-storage.nix`, which now applies only to node-C until C is
converted) for nodes A and B.

> Read order: **doc 09** (design/ADRs, the *why*) → **doc 10** (phased plan,
> layout/peering/gateway/data-plane) → **doc 12** (node-B USB mechanics in full)
> → this doc (the A→B sequence + node-A). Docs 09/10 were authored in the prod
> repo; their bare `documentations/0X-*.md` and Flux/k8s paths point there.

---

## Quickstart — the lifecycle tool (`scripts/fleet`)

`scripts/fleet` is the single workstation entrypoint for the whole node lifecycle
(it replaces the former `bootstrap-node` + `deploy-node`). Run it bare for a TUI,
or use subcommands:

```bash
./scripts/fleet                                   # TUI menu (status + actions)
./scripts/fleet new    node-a                     # scaffold + secrets (idempotent; --force regens)
./scripts/fleet install node-a root@<installer-ip># REMOTE provision (nixos-anywhere)
./scripts/fleet deploy  node-a                    # apply a config change (deploy-rs + auto-rollback)
./scripts/fleet status                            # readiness + lifecycle state per node
```

| Command | Does (automated) | You still do |
|---|---|---|
| `new <node>` | fleet age key; `.sops.yaml` recipient; `common.enc.yaml` (rpc/admin/metrics, **no** zfs-passphrase); per-node SSH host key → `private-keys/` → `ssh-to-age` recipient → `.sops.yaml`; node authkey; `sops updatekeys`. For a **brand-new** node also scaffolds `hosts/*.nix` + disko + the `flake.nix` entry. Re-running SKIPS what exists | mint the `tag:garage` auth key + set the Tailscale ACL; copy the fleet age key to break-glass; fill the scaffolded `hostId` / device paths / capacities |
| `install <node> root@host` | REMOTE `nixos-anywhere`: feeds the encryption passphrase(s) to the installer's RAM (`--disk-encryption-keys`), seeds the host key (`--extra-files`), installs `.#<node>-install`, then restores `keylocation=prompt` over ssh. **node-A feeds TWO** pairs (dpool ZFS + cryptwork LUKS); the pre-wipe guard confirms the seeded host key matches the sops recipient | confirm `lsblk` device paths; type the passphrase(s); **node-A**: be at the console for the first LUKS prompt, then do the Secure-Boot/TPM enrollment (`modules/secureboot.nix`); apply the Garage layout once (`fleet guide`) |
| `deploy <node>` | `deploy-rs` push with **magic-rollback** (auto-reverts a change that breaks reachability). First push warns: no rollback baseline yet | keep a console reachable for that **first** push |
| `secrets` | list / `sops` edit / **verify-all-encrypted + git-stage** / `updatekeys` | `git commit && git push` the encrypted files |
| `config tailnet <name>` | writes the MagicDNS tailnet into `flake.nix` (deploy targetHosts) | — |

Prefer the **remote** path (`install`). Validate the flake on a nix host with
`nix flake check`. The on-box console/USB steps in the sections below are the
**fallback** when a node can't be reached over the network for `nixos-anywhere`
(also printed by `fleet guide <node>`), and remain the source of truth for what
happens on the box — physical USB boot, `disko`/`nixos-install`/`zfs load-key`/
`garage layout`, the Tailscale console, and break-glass custody are **MANUAL**.

---

## 0. What is already done in the repo (and what you must still do)

This runbook was prepared **with the repo edits already applied** so the code and
the docs finally agree. Already committed/staged for you:

| Done | Where |
|---|---|
| Fleet-wide module options `fleet.zfsAutoUnlock / dataDirs / advertiseRoutes / sanoidDatasets` | `modules/base.nix`, `garage.nix`, `tailscale.nix`, `zfs-sanoid.nix` |
| `zfs-passphrase` sops secret gated on `zfsAutoUnlock` (not role) | `modules/sops.nix` |
| Multi-disk `data_dir` + `ConditionPathIsMountPoint` start-gate | `modules/garage.nix` |
| node-A dual-ROLE host: onsite Garage (HDD `dpool`, prompt-unlock) **+** dev workstation (NVMe LUKS/TPM `wpool`, ROOT docker) + Secure Boot | `hosts/node-a.nix`, `disko-node-a.nix`, `node-a-hardware.nix`, `modules/workstation.nix`, `modules/secureboot.nix` |
| node-B dual-disk prompt-unlock host + disko + hardware (per doc 12) | `hosts/node-b.nix`, `disko-node-b.nix`, `node-b-hardware.nix` |

**Validated on real nix** (this is more than docs 11/12 could check):

- `nix eval .#nixosConfigurations.node-a` and `…node-b` **fully evaluate to a
  toplevel system derivation** once the two Phase-0 inputs below exist.
- `services.garage.settings.data_dir` renders as a **multi-disk array-of-tables**
  `[{path,capacity},…]` → confirmed both disks are used.
- Under prompt-unlock the `zfs-passphrase` secret is **absent** (good); only
  `rpc_secret / admin_token / metrics_token / tailscale-authkey` are present.
- `garage` waits for `ConditionPathIsMountPoint = [meta, data-ssd, data-hdd]`.

> ⚠️ **node-A was reworked TWICE since this validation:** (1) dev-workstation with
> Garage on a **single `data_dir`** on the HDD (`ConditionPathIsMountPoint = [meta,
> data-hdd]`); (2) the **LUKS/TPM/lanzaboote** two-trust-domain rework — NVMe is now
> ESP + swap + LUKS `cryptwork` → ZFS-root `wpool` {root, sysadmin home, docker}, all
> Garage on the encrypted HDD `dpool`. **`nix flake check` passes for the current
> node-A** (verified). The multi-disk `data_dir` facts above still describe **node-B**.

**⚠️ Two things STILL block a full build until you do them (Phase 0):**

1. **SSH keys** — `modules/base.nix` ships the `ops` + `root`
   `authorizedKeys.keys` lists **empty**. NixOS refuses to build a box with no
   login (`Neither the root account nor any wheel user has a password or SSH
   authorized key`). Paste your key(s) in §0.2.
2. **Real secrets** — only `secrets/*.enc.yaml.example` exist. You must create
   the real encrypted `secrets/common.enc.yaml` + per-node tailscale files
   (§0.3–0.4).

**⚠️ Garage version pin is NOT satisfied by the current channel.** On the pinned
`nixpkgs/nixos-25.05`, **`pkgs.garage_2` resolves to `2.1.0`**, not the
design-pinned `2.3.0` (there is no `garage_2_3_0` attr — only `garage_1_3_0` /
`garage_2_1_0`). Deploying as-is installs **2.1.0**. Both are v2.x (layout-format
compatible), but to honour the pin, **bump the `nixpkgs` flake input** to a rev
where `garage_2 == 2.3.0` (or add an overlay) before cutover — a
Renovate/operator action (doc 10 Phase 8). Verify after locking:
`nix eval --raw .#nixosConfigurations.node-a.config.services.garage.package.version`.

**Scope boundary — A+B is an *incomplete* cluster.** `replication_factor = 3`
(identical on every node). With only A+B (2 zones) Garage **cannot place the full
3 replicas** → the cluster runs **under-replicated/degraded** until **node-C**
(zone `offsite-2`) joins. The full-mirror + site-loss tolerance gate is **doc 10
Phase 2**, reached only at 3 storage zones. Do not treat A+B as durable yet.

---

## 0.1 Workstation tooling

From the repo root (this repo *is* `garage-fleet`):

```bash
mise install                       # sops, age, jq, gh, shellcheck (mise.toml)
nix --version                      # flakes-enabled nix (2.x)
# ssh-to-age: from mise (mise.toml) or `nix run .#ssh-to-age -- …` (below).
# NOT `nixpkgs#ssh-to-age` — that resolves via the flake registry (unstable),
# bypassing flake.lock. `scripts/fleet` picks whichever is present.
```

Security invariants (from doc 09/12, do not break):

- **dpool ZFS passphrase** (the MANUAL gate) **never** stored on the box **or in any
  sops file** — typed at format, re-typed at each unlock. Keep it offline (password
  manager + a second physical copy). `<node>.enc.yaml` SHIPS to the node and the node
  can decrypt it (its age key comes from its SSH host key — on the **unencrypted**
  root on B/C, on node-A's **TPM-unlocked** root), so a stored dpool passphrase = a
  stolen box unlocks its own backups. `keylocation=prompt` has **no recovery path** —
  lose it, lose the pool.
- **node-A's LUKS passphrase** (cryptwork keyslot-0, the TPM **recovery** secret) is
  ALSO offline-only, and a **DIFFERENT** secret from the dpool one — see
  [Why node-A has 2 passphrases](#why-node-a-has-2-passphrases-and-node-bc-have-1).
- **One passphrase PER NODE**, never one shared across the fleet. A shared value in
  `common.enc.yaml` (encrypted to every node) means compromising node-A — which
  runs arbitrary devcontainer code as effective root — yields node-B's and
  node-C's too.
- ⚠️ **The fleet age key never lands on node-A.** `private-keys/garage-fleet.txt`
  decrypts EVERY node's secrets. node-A is the DevPod host with `sysadmin` in the
  `docker` group (root-equivalent), so copying the key there to run `fleet` locally
  hands the whole fleet to anything that escapes a container. Run `fleet` from the
  workstation devcontainer; node-A is for dev work only. Break-glass copy goes in
  the password manager — `private-keys/` is gitignored and CANNOT be regenerated.
- Only the `$6$` **hash** of each node's root password goes in `<node>.enc.yaml`;
  the plaintext lives in the password manager. Unique per node — reuse turns your
  most exposed box into the weakest link for a credential used elsewhere.
- SSH host **private** key reaches the box by **direct copy** to `/mnt/etc/ssh`,
  **never** through the Nix store.
- The `garage` user gets **zero** `zfs allow` (the snapshot moat depends on it).
  ⚠️ On node-A the `sysadmin` workstation user IS in the `docker` group
  (root-equivalent) — a deliberate moat trade (`modules/workstation.nix`): node-A's
  moat is advisory, the real moat lives on B/C. It still holds no direct `zfs allow`.
- Fleet secrets are a **separate trust domain** — never reuse the prod cluster's
  `age137z0k…` / `age1heestk…` keys.
- Every Garage listener binds the **`tailscale0` overlay IP only**, never `0.0.0.0`.

## 0.2 SSH keys (`modules/base.nix`)

`modules/base.nix` defines **one** human operator user, `sysadmin` (isNormalUser,
`wheel` → sudo, uid 2000), plus **key-only** `root` (for deploy-rs / nixos-anywhere).
Both carry the operator's SSH **public** key — confirm it is yours:

```nix
  users.users.sysadmin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];                 # + "docker" on node-A (workstation.nix)
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA…YOURKEY you@mac" ];
  };
  users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA…YOURKEY you@mac" ];
```

**node-A DevPod login** = the same `sysadmin` user. `modules/workstation.nix` adds it
to the `docker` group (node-A only) so DevPod reaches the **root** docker daemon's
`/var/run/docker.sock` — no separate `dev` user, no `DOCKER_HOST` override. (The
docker group is root-equivalent: a deliberate moat trade documented in
`workstation.nix`.)

## 0.3 Mint fleet secrets (prompt-unlock variant)

```bash
./secrets/gen-secrets.sh           # prints fleet age RECIPIENT + rpc/admin/metrics
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/garage-fleet.txt"
```

Paste the printed `age1…` **recipient** into `.sops.yaml`, replacing the
`age1FLEET…` placeholder.

> **Prompt-unlock ⇒ do NOT put `zfs-passphrase` in `common.enc.yaml`.**
> `modules/sops.nix` only declares that secret when `fleet.zfsAutoUnlock = true`,
> and both node-A and node-B set it `false`. Including it would be dead, and the
> passphrase must never live on the box.

```bash
cp secrets/common.enc.yaml.example secrets/common.enc.yaml
$EDITOR secrets/common.enc.yaml      # paste rpc_secret/admin_token/metrics_token; DELETE the zfs-passphrase line
sops -e -i secrets/common.enc.yaml
```

Per-node Tailscale auth keys (mint each in the admin console: **reusable,
non-ephemeral, `tag:garage`, long/no expiry**):

```bash
for n in node-a node-b; do
  cp secrets/node.enc.yaml.example secrets/$n.enc.yaml
  $EDITOR secrets/$n.enc.yaml      # paste tskey-auth-…
  sops -e -i secrets/$n.enc.yaml
done
```

## 0.4 Pre-generate each node's SSH host key = its sops identity

Each node's age identity = `ssh-to-age` of its Ed25519 host key. Generate both
**now** so the secrets can be encrypted *to* them before install. `node-*-extra/`
is gitignored (never commit a host private key).

```bash
for n in node-a node-b; do
  install -d -m700 $n-extra/etc/ssh
  ssh-keygen -t ed25519 -N "" -C $n -f $n-extra/etc/ssh/ssh_host_ed25519_key
  echo "== $n recipient =="; nix run .#ssh-to-age -- -i $n-extra/etc/ssh/ssh_host_ed25519_key.pub
done
```

Add **both** recipients to `.sops.yaml` (anchors + under **both** creation rules),
then re-encrypt so each node can decrypt the shared secrets and its own authkey:

```yaml
keys:
  - &fleet_workstation age1…      # from 0.3
  - &node_a            age1…      # node-A ssh-to-age (0.4)
  - &node_b            age1…      # node-B ssh-to-age (0.4)

creation_rules:
  # Shared secrets → every node + workstation (any node decrypts the shared rpc_secret).
  - path_regex: secrets/common\.sops\.ya?ml$
    key_groups: [ { age: [ *fleet_workstation, *node_a, *node_b ] } ]
  # Per-node authkey → ONLY its node + workstation (minimal blast radius — a
  # tag:garage authkey is a cluster-join credential, doc 09 §8). List the specific
  # rules BEFORE any generic `*-tailscale` rule so sops matches the right one.
  - path_regex: secrets/node-a\.enc\.ya?ml$
    key_groups: [ { age: [ *fleet_workstation, *node_a ] } ]
  - path_regex: secrets/node-b\.enc\.ya?ml$
    key_groups: [ { age: [ *fleet_workstation, *node_b ] } ]
```

```bash
sops updatekeys secrets/common.enc.yaml
sops updatekeys secrets/node-a.enc.yaml
sops updatekeys secrets/node-b.enc.yaml
sops -d secrets/common.enc.yaml >/dev/null && echo "decrypt OK"
grep -L 'sops:' secrets/*.enc.yaml || echo "all sops files encrypted"   # must print nothing but the echo
```

## 0.5 Tailscale ACL (deny-by-default)

In the Tailscale admin console (doc 09 §3):

- `tag:garage → tag:garage` on `tcp:3900,3901,3903` (the fleet talks to itself).
- `tag:k8s → tag:garage` on **`tcp:3900` ONLY** (prod S3) — **never** `3901`
  (RPC peering) and **never** `3903` (admin/control).
- Pre-approve node-B's advertised subnet route / exit-node (the scraper-egress
  role). node-A advertises nothing (not a proxy).

## 0.6 Break-glass custody (the one deliberately-manual control)

Offline, in **two physical locations** (paper/steel + password manager), store:
the **ZFS passphrase** (you'll choose it at format in §A.3/§B), the fleet age
**private** key (`$HOME/.config/sops/age/garage-fleet.txt`), and the
restic/Kopia/etcd-age repo passwords. These are catastrophic-loss — the ZFS key
is unrecoverable from a lost node fleet (doc 09 §8).

## 0.7 Per-host placeholders to confirm now (search `TODO operator`)

| File | Set |
|---|---|
| `hosts/node-a.nix` | `networking.hostId` (unique 8-hex, `head -c4 /dev/urandom \| od -A none -t x4`); `dataDirs` capacity (HDD only now); `tailscaleIp` is set **after** first join (§A.5) |
| `hosts/node-b.nix` | same; plus `advertiseRoutes` (the LAN CIDR this proxy serves) |
| `hosts/disko-node-a.nix`, `disko-node-b.nix` | NVMe/HDD `device =` paths — **confirm with `lsblk` on the live USB** before formatting. node-A: NVMe → ESP+swap+LUKS `cryptwork`→`wpool` (OS/dev), HDD → `dpool` (Garage) |
| `modules/base.nix` / `modules/workstation.nix` | `sysadmin` SSH key = your Mac (§0.2, in base.nix); ARC cap in workstation.nix if you want ≠4 GiB; `fleet.secureBoot` stays `false` until §A.5b |
| `hosts/node-a-hardware.nix` | **defaults to the M715q module** — regenerate on the box if node-A is different hardware (see the file header) |

## 0.8 Lock + sanity-check the flake

```bash
nix flake lock                     # no-op if flake.lock is already committed (it is)
nix flake check                    # deploy-rs schema + eval (needs §0.2 + §0.3 done)
nix eval --raw .#nixosConfigurations.node-a.config.services.garage.package.version   # see the 2.1.0 vs 2.3.0 note
```

## 0.9 Make the installer USB + stage the payload

```bash
# Minimal x86_64 ISO matching the pinned channel:
curl -L -o nixos-minimal.iso \
  https://channels.nixos.org/nixos-25.05/latest-nixos-minimal-x86_64-linux.iso
lsblk                              # IDENTIFY the USB, e.g. /dev/sdX (size + RM flag)
sudo dd if=nixos-minimal.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

> ⚠️ `dd of=` must be the **USB**, never your workstation disk.

On a **second** USB (the payload), copy the whole repo **plus** the per-node
`*-extra/` dir (gitignored, so it is not in the working-tree copy):

```
garage-fleet/                                   # whole dir incl. encrypted secrets/*.enc.yaml
garage-fleet/node-a-extra/etc/ssh/ssh_host_ed25519_key{,.pub}
garage-fleet/node-b-extra/etc/ssh/ssh_host_ed25519_key{,.pub}
```

**Phase 0 gate:** `nix flake check` passes; `sops -d secrets/common.enc.yaml`
works; ACL saved + `tag:garage` exists + 2 authkeys minted; break-glass in 2
locations; both installer + payload USBs ready.

---

## Why node-A has 2 passphrases and node-B/C have 1

The count of human-held secrets = the count of encryption domains that need one.

| | node-B / node-C | node-A |
|---|---|---|
| **root fs** | **unencrypted** ext4 → boots unattended, no secret | **LUKS2 (`cryptwork`)**, TPM2-auto → a domain that needs a **recovery** secret |
| **Garage data** | ZFS-native `keylocation=prompt` → 1 secret | ZFS-native `keylocation=prompt` → 1 secret |
| **human-held secrets** | **1** (ZFS data) | **2** (LUKS recovery + ZFS data) |

- **node-B/C** encrypt only their **data** pools. Their root is plain ext4 (so they
  boot unattended and you unlock data over the mesh), and the ZFS data passphrase is
  the single secret. Encrypting root wasn't chosen for them: they're headless storage
  appliances, and a stolen box's *data* already stays ciphertext behind the ZFS gate.

- **node-A** also encrypts its **root** — because it's your daily-driver workstation
  and its root/home/docker hold dev source. That adds a *second* encryption domain
  (LUKS), and LUKS needs a passphrase in keyslot 0. The TPM normally supplies the key
  automatically (so day-to-day you type **nothing** for root), but that keyslot-0
  passphrase is the **recovery** secret for when a firmware/kernel update rotates
  PCR 7 and the TPM refuses.

So node-A doesn't have "two routine unlocks." Routine node-A is still **one** manual
step — `zfs load-key dpool/garage` over the mesh, same as B/C. The LUKS passphrase is
a rarely-used **recovery** key, and the install prompts for both only because both
keyslots must be seeded at format time. They are **deliberately different secrets**:
the LUKS one guards a domain (root, at-rest) the TPM automates; the ZFS one is the
routine manual gate. Both live offline in the break-glass vault.

---

## Phase A — install node-A (onsite) → single-node cluster, layout v1

`disko` **destroys both of node-A's disks**. node-A holds no backups yet, so this
is safe (doc 10 risk register). Have monitor + keyboard + wired ethernet attached.

### A.1 Boot the USB, confirm disks

Plug installer USB + payload USB + monitor/keyboard/ethernet → power on → boot
menu (Lenovo = **F12**) → the installer USB. Then:

```bash
sudo -i
ping -c1 nixos.org                 # DHCP up
lsblk                              # CONFIRM the NVMe (ESP+swap+cryptwork→wpool) and HDD (dpool = all Garage)
```

> If device names differ from `hosts/disko-node-a.nix` (`/dev/nvme0n1`,
> `/dev/sda`), **edit `device =` on the payload copy before A.3.**

### A.2 Get the flake onto the live system

```bash
mkdir -p /mnt-usb && mount /dev/sdY1 /mnt-usb      # the PAYLOAD usb (lsblk to find)
cp -r /mnt-usb/garage-fleet /root/garage-fleet
ls /root/garage-fleet/node-a-extra/etc/ssh/        # host key present?
export NIX_CONFIG="experimental-features = nix-command flakes"
cd /root/garage-fleet && { [ -f flake.lock ] || nix flake lock; }
```

### A.3 Partition + format (prompts for BOTH passphrases)

> Preferred: skip the USB and run `fleet install node-a root@<ip>` from the
> workstation — it prompts for both passphrases, feeds them via two
> `--disk-encryption-keys` pairs, and runs the pre-wipe recipient guard. The manual
> `disko` below is the fallback; the runtime variant has no install keyfiles, so
> disko prompts interactively for both.

```bash
nix run .#disko -- \
  --mode destroy,format,mount --flake .#node-a --yes-wipe-all-disks
```

- **DESTROYS** the NVMe + HDD; creates ESP (2G) + swap (8G) + LUKS2 `cryptwork` →
  ZFS-root `wpool` {root, sysadmin home, docker} on the NVMe, and encrypted `dpool`
  (all Garage) on the HDD.
- It pauses **TWICE** — two DIFFERENT secrets, both the *only* copy, both offline now:
  1. **LUKS passphrase** for `cryptwork` (the TPM-auto root domain). Becomes keyslot
     0 = the **TPM recovery** key.
  2. **ZFS passphrase** for `dpool/garage` (the manual gate you re-type each unlock).

```bash
zfs list                           # wpool/{root,home,docker}, dpool/garage/{meta,data}
ls -la /mnt/srv/garage/            # meta, data-hdd mountpoints
ls -la /mnt/home/sysadmin          # sysadmin home on wpool
```

### A.4 Inject the SSH host key + install

The pre-generated host key (matches the sops recipient from §0.4) must land
**before** first activation or sops can't decrypt.

```bash
install -d -m700 /mnt/etc/ssh
cp /mnt-usb/garage-fleet/node-a-extra/etc/ssh/ssh_host_ed25519_key      /mnt/etc/ssh/
cp /mnt-usb/garage-fleet/node-a-extra/etc/ssh/ssh_host_ed25519_key.pub  /mnt/etc/ssh/
chmod 600 /mnt/etc/ssh/ssh_host_ed25519_key
chmod 644 /mnt/etc/ssh/ssh_host_ed25519_key.pub

nixos-install --flake /root/garage-fleet#node-a --no-root-passwd
umount -R /mnt && zpool export -a
reboot                             # pull the installer USB during reboot
```

### A.5 First boot: console LUKS unlock, join the tailnet, fix the overlay IP

⚠️ **This first boot is NOT unattended.** The TPM is not enrolled yet (that is the
one-time trip in §A.5b), so systemd-cryptsetup falls back to a **console passphrase
prompt** for `cryptwork`. **Be at the keyboard** and type the **LUKS** passphrase
(§A.3.1) within ~60 s of the prompt — the initrd ZFS root-import has a short patience
window; miss it and boot drops to an initrd emergency shell (just reboot and retry).

Once `cryptwork` unlocks, `wpool` imports, `wpool/root` mounts as `/`, and stage-2
runs: sops decrypts (host key on `wpool/root`) → tailscale auto-joins with the
authkey. `wpool/{root,home,docker}` are up; `dpool` imports but stays **locked**.

```bash
tailscale status                   # note node-A's real 100.x.y.z
zfs get keystatus dpool/garage     # unavailable (locked) — expected; wpool is TPM-unlocked, already mounted
systemctl status garage            # inactive (ConditionPathIsMountPoint) — expected
```

The guessed `fleet.tailscaleIp` in `node-a.nix` is almost certainly wrong, and
Garage binds that exact IP. Set the real one and rebuild locally (the
bootstrap before a deploy-rs baseline exists):

```bash
sudo cp -r /mnt-usb/garage-fleet /root/garage-fleet     # if USB still attached
# edit hosts/node-a.nix: fleet.tailscaleIp = "100.x.y.z"
sudo nixos-rebuild switch --flake /root/garage-fleet#node-a
```

Commit that `tailscaleIp` on the workstation branch too (source of truth = box).

### A.5b Enroll Secure Boot + seal the TPM (node-A only, one-time console trip)

Until this is done, **every** node-A boot needs the console LUKS passphrase (§A.5).
The goal: reboots unlock root **unattended** from the TPM. The full step-by-step
(with the exact commands + the WHY) lives in **`modules/secureboot.nix`** — follow it
there. The ORDER is load-bearing and easy to get wrong; the summary:

1. First deploy while still on systemd-boot (`fleet.secureBoot = false`, the default)
   to get a deploy-rs rollback baseline.
2. `sudo sbctl create-keys` (writes `/etc/secureboot`).
3. **Sign the UKIs BEFORE turning Secure Boot on:** flip `fleet.secureBoot = true` in
   `hosts/node-a.nix`, commit, `fleet deploy node-a` (this activates lanzaboote and
   signs every UKI), then `sudo sbctl verify`. Enabling SB before this leaves nothing
   signed to verify → unbootable.
4. Firmware → Setup Mode → `sudo sbctl enroll-keys --microsoft` → enable Secure Boot →
   set a **firmware supervisor password**.
5. **Seal the TPM ONLY NOW,** after SB is on, so PCR 7 reflects the final state:
   `sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-nvme-cryptwork`
   (authorize with the LUKS passphrase). Sealing before SB is enabled binds PCR 7 to
   the wrong state and the next boot won't unlock.
6. Reboot — cryptwork now unlocks unattended. Confirm the LUKS passphrase survived as
   a recovery keyslot: `sudo cryptsetup luksDump …disk-nvme-cryptwork` shows keyslot 0
   **and** a `systemd-tpm2` token.

The LUKS passphrase stays your only way back after a firmware/dbx update rotates
PCR 7 — keep it in the break-glass vault.

### A.6 Unlock the data pool + start Garage

```bash
sudo zfs load-key -a               # prompts ONCE — only dpool/garage is encrypted
sudo zfs mount -a
mount | grep /srv/garage           # meta, data-hdd mounted
sudo systemctl start garage
systemctl status garage            # active (running)
```

### A.7 Single-node layout (version 1)

```bash
export GARAGE="sudo garage"
$GARAGE status                     # shows node-A's ID, HEALTHY
NODE_ID=$($GARAGE node id -q | cut -d@ -f1)
$GARAGE layout assign "$NODE_ID" -z onsite -c <bytes>   # e.g. 900G — node-A HDD only (all Garage on dpool)
$GARAGE layout show                # review STAGED
$GARAGE layout apply --version 1   # exactly prev+1, ONCE
$GARAGE status
```

### A.8 Smoke test S3 (over the tailnet)

```bash
$GARAGE bucket create smoke
$GARAGE key create smoke-key       # note the Access Key ID + Secret
# from any tag:garage device:
aws --endpoint-url http://100.x.y.z:3900 --region garage s3 ls
$GARAGE bucket info smoke
```

**Phase A gate:** after TPM enrollment (§A.5b) boots unattended (before it, the
console LUKS passphrase); `dpool` `unavailable` until `load-key` (the `wpool` OS/dev
pool is TPM-unlocked and already mounted); garage inactive pre-unlock; listeners
bound to `100.x.y.z` (not `0.0.0.0`) — `ss -tlnp | grep -E '3900|3901|3903'`;
`/run/secrets/` has rpc/admin/metrics + tailscale-authkey and **no** `zfs-passphrase`;
`zfs allow dpool/garage` shows the `garage` user **nowhere** (`sysadmin` reaches root
via docker but holds no direct `zfs allow`); `data-hdd` used (single `data_dir`);
`sanoid.timer` active.

### A.9 Verify the dev workstation (node-A dual-role)

node-A also hosts your devcontainers — a **root docker** daemon (zfs storage
driver, data-root on `wpool/docker`), driven from the Mac via DevPod. Independent of
Garage: it works the moment `wpool` is up; the encrypted `dpool` does **not** need
unlocking for dev work.

On node-A:

```bash
docker info | grep -A2 'Storage Driver'           # expect: zfs (NOT a vfs fallback)
id sysadmin                                        # groups include wheel + docker
zfs allow dpool/garage                             # sysadmin holds no direct zfs allow
```

From the **Mac** (your key is on the `sysadmin` user, §0.2):

```bash
devpod provider add ssh --option HOST=sysadmin@node-a.<tailnet>.ts.net
devpod up <repo> --provider ssh --ide vscode
```

The docker CLI defaults to `/var/run/docker.sock`, reached via the `docker` group —
no `DOCKER_HOST` override. Full envelope: `--privileged`, docker-in-docker, host
ports <1024 all work. ZFS ARC is capped at 4 GiB to leave RAM for containers.

> ⚠️ **Moat trade:** the `docker` group is root-equivalent, so on node-A a container
> escape / hostile devcontainer dep can reach root and `zfs destroy dpool/garage@*`.
> node-A's moat is advisory by design; the real moat is B/C. `sysadmin`'s sshd sets
> `AllowAgentForwarding no` so a forwarded key can't be reused to reach root on B/C.

**Phase A (workstation) gate:** `docker info` shows the `zfs` driver; `devpod up`
builds and the IDE attaches; `dpool` can stay locked and dev still works;
`zfs allow dpool/garage` lists no `garage` user.

---

## Phase B — install node-B (offsite-1) → **join** node-A, layout v2

node-B's USB mechanics are **identical** to Phase A with `node-b` substituted, so
follow **doc 12 §2–§7** (or repeat §A.1–§A.5 with `node-b` / `node-b-extra` /
`.#node-b`). node-B differs only in: it is a **proxy** (set `advertiseRoutes`),
and it **joins node-A's existing cluster** instead of starting its own. node-B
keeps the **dual-encrypted** layout (NVMe `npool` + HDD `dpool`, two passphrase
prompts) — it is **not** a workstation, so it does not use `wpool`.

### B.1 Install node-B (USB), up to "Garage running, single node"

Repeat §A.1–§A.6 with `node-b`:

- §A.1 confirm `nvme0n1` (500G) + `sda` (1T) on the M715q; edit
  `hosts/disko-node-b.nix` if different.
- §A.3 `disko … --flake .#node-b --yes-wipe-all-disks` — **use the SAME fleet ZFS
  passphrase** as node-A (one passphrase to remember), or a distinct one if you
  prefer per-node (then record both offline). node-B prompts **twice** (`npool` +
  `dpool`).
- §A.4 inject from `node-b-extra/`, `nixos-install --flake …#node-b`.
- §A.5 set `fleet.tailscaleIp` to node-B's real IP; **also set
  `fleet.advertiseRoutes = [ "192.168.x.0/24" ]`** for the scraper-egress role
  (approve the route in the ACL, §0.5); `nixos-rebuild switch`.
- §A.6 `zfs load-key -a` + `zfs mount -a` + `systemctl start garage`.

At this point node-B is a **separate** Garage with **no layout** (version 0, no
role assigned) — do **NOT** run `layout assign/apply` on node-B standalone. Join
it to node-A first; then node-A's existing layout (v1) is bumped to v2 to include
node-B (§B.3).

### B.2 Peer node-B into node-A's cluster

Garage forms the gossip cluster over the tailnet via the shared `rpc_secret` +
RPC reach (ACL `tag:garage ↔ tag:garage` on `3901`). Get node-A's full id and
connect from node-B (one-time imperative join):

```bash
# on node-A:
sudo garage node id -q             # -> <pubkeyA>@100.x.y.A:3901   (full id incl. addr)

# on node-B:
sudo garage node connect <pubkeyA>@100.x.y.A:3901
sudo garage status                 # BOTH node-A and node-B now listed, HEALTHY
```

**Make the peering survive reboots** — set `bootstrap_peers` in
`modules/garage.nix` to **both** nodes' `pubkey@overlay:3901`, then redeploy both
(now that a generation exists, use deploy-rs with magic rollback):

```nix
        bootstrap_peers = [
          "<pubkeyA>@100.x.y.A:3901"
          "<pubkeyB>@100.x.y.B:3901"
        ];
```

```bash
# workstation, per node (or `mise run deploy` for node-b):
nix run .#deploy-rs -- .#node-a --remote-build
nix run .#deploy-rs -- .#node-b --remote-build
```

> ⚠️ First post-install deploy-rs push has **no canary baseline**, so magic
> rollback can't save a bad tailscaled/firewall change yet — keep console / the
> box reachable for this first push (doc 09 ADR-4, flake.nix note).

### B.3 Two-zone layout (version 2)

From **either** node (node-A already holds layout v1 with itself assigned; this
**adds** node-B and bumps to v2):

```bash
export GARAGE="sudo garage"
ID_B=$($GARAGE node id -q | cut -d@ -f1)      # run on node-B, or use its known id
$GARAGE layout assign "$ID_B" -z offsite-1 -c <bytes>
$GARAGE layout show                 # STAGED: node-A onsite (v1) + node-B offsite-1
$GARAGE layout apply --version 2    # exactly prev+1, ONCE — never apply the same version twice
# after it settles (minutes):
$GARAGE repair -a --yes tables
```

### B.4 What works now — and what does NOT (the honest gate)

**Phase B gate (what you CAN verify):**

- `garage status` lists **both** nodes HEALTHY, in 2 distinct zones (`onsite`,
  `offsite-1`); `garage layout show` = version 2.
- An object PUT via node-A's S3 is readable via node-B's S3 endpoint (data is
  reaching the second node).
- node-B still serves its **scraper-egress** proxy role (the in-cluster scrape
  path is unaffected); `tailscale status` shows the advertised route approved.
- Both nodes: listeners tailnet-only; moat invariant (`zfs allow …` → no `garage`
  user); sanoid snapshotting the Garage datasets (node-A: `dpool/garage`; node-B:
  `npool/garage` + `dpool/garage`).

**What is NOT yet true (do not over-trust A+B):**

- **No full 3× mirror and no site-loss tolerance.** `replication_factor = 3` with
  only 2 zones is **under-replicated** — Garage cannot place the third replica.
  The full-mirror + "stop a node, quorum still met" drill is **doc 10 Phase 2**,
  valid only once **node-C** (zone `offsite-2`) joins (`layout apply --version 3`).
- node-D (gateway, the prod S3 entry point) is **doc 10 Phase 3**; the data-plane
  backup jobs are **doc 10 Phase 4** (prod repo, Flux).

---

## Routine ops (after any reboot)

Both boxes come back on their own, but Garage stays **down until you unlock**
(prompt-unlock, by design — a stolen offsite box stays locked):

```bash
ssh sysadmin@node-b.<tailnet>.ts.net
sudo zfs load-key -a && sudo zfs mount -a
sudo systemctl start garage
```

On **node-A** the OS + dev workstation (`wpool`: root, home, docker) is already up —
`wpool` unlocks from the **TPM** in initrd, unattended, so sshd/tailscale/docker come
back on their own. Only Garage waits for the `dpool` unlock above. (Until the TPM is
enrolled — §A.5b — node-A's `wpool` needs the **console LUKS passphrase** at each
boot instead.)

Never store the dpool passphrase on the box (that defeats prompt-unlock). For the
onsite node-A you *may* opt `dpool` into auto-unlock, but flipping
`fleet.zfsAutoUnlock = true` **alone is not enough** — you must also switch
`dpool/garage` `keylocation` to a `file://…` URL in `hosts/disko-node-a.nix` and add
a boot load-key unit (doc 12 §9(a)), accepting the weaker theft story. node-A's
`wpool` is a separate concern: it is LUKS/TPM and auto-unlocks in initrd regardless.

## Relation to other docs

- **doc 12** — node-B USB mechanics in full (this doc reuses them; the *only*
  additions here are node-A and the A→B join/layout-v2 sequence).
- **doc 11** — the superseded `dd`/image-flash method; keep only as the
  flash-from-another-machine fallback.
- **doc 10** — node-C (Phase 2, completes the 3-zone factor-3 mirror), node-D
  gateway (Phase 3), data-plane backup jobs (Phase 4+), monitoring, restore
  drills. **Continue there after A+B.**
- **doc 09** — design, ADRs, the moat, boot-trust, secrets inventory.

## Appendix — repo changes applied for this design (for reviewers)

Reconciliation from the single-disk auto-unlock skeleton to the dual-disk
prompt-unlock model (so docs 11/12 and the code agree):

- `modules/base.nix` — added `fleet.zfsAutoUnlock` option (default `false`).
- `modules/sops.nix` — `zfs-passphrase` now gated on `fleet.zfsAutoUnlock`
  (was `role == "storage"`), so prompt-unlock nodes persist no passphrase.
- `modules/garage.nix` — added `fleet.dataDirs` option; `data_dir` becomes the
  multi-disk list when set; added `systemd.services.garage.unitConfig`
  `ConditionPathIsMountPoint` so Garage waits for the unlocked mounts.
- `modules/tailscale.nix` — added `fleet.advertiseRoutes`; the proxy branch emits
  `--advertise-routes` from it.
- `modules/zfs-sanoid.nix` — added `fleet.sanoidDatasets` (default
  `[ "bpool/garage" ]`); the dataset map is generated from it so dual-disk nodes
  snapshot `npool/garage` + `dpool/garage`. **node-A snapshots only
  `dpool/garage`** — its NVMe `wpool` is the dev pool, not a moat dataset.
- `hosts/node-a.nix` + `disko-node-a.nix` + `node-a-hardware.nix` — node-A's
  **two-trust-domain** rework: NVMe = ESP + swap + LUKS2 `cryptwork` (TPM2/PCR-7
  auto-unlock) → **ZFS-root** `wpool` {root, sysadmin home, docker}; all Garage on the
  encrypted HDD `dpool` (prompt-unlock, single `data_dir`). Root is a `wpool` dataset,
  not a fixed partition.
- `modules/secureboot.nix` — **new** (node-A only): lanzaboote signed UKIs + systemd
  stage-1 initrd + TPM2 LUKS unlock, staged on `fleet.secureBoot`, plus the on-box
  enrollment runbook.
- `modules/workstation.nix` — **new** (node-A only): **ROOT-docker** devcontainer host
  for DevPod — `sysadmin` (uid 2000) in the `docker` group (root-equivalent, a
  deliberate moat trade), docker `zfs` driver on `wpool/docker`, agent-forwarding-off
  via sshd `Match User sysadmin`, ZFS ARC cap. Co-located with the DR Garage role.
- `hosts/node-b.nix` + `disko-node-b.nix` + `node-b-hardware.nix` — **new/rewritten**
  per doc 12.
- `hosts/node-c.nix` / `node-d.nix` — **unchanged**. node-C still imports the
  single-disk `disko-storage.nix`; convert it to the dual-disk model (copy
  node-A's HDD-`dpool` Garage layout) when you install it, or keep single-disk per
  its hardware.
