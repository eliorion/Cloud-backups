# 13 — node-A + node-B install runbook (USB, dual-disk, prompt-unlock)

The single, ordered, copy-paste runbook for installing the **first two** fleet
nodes from bare metal to a running Garage cluster:

- **node-A** — zone `onsite`, storage **+ dev workstation** (Phase 1,
  `modules/workstation.nix`). *No prior install doc existed; this fills that gap.*
- **node-B** — zone `offsite-1`, storage **+** Tailscale scraper-egress proxy.
  Detailed mechanics already in **doc 12**; here node-B is installed as the node
  that **joins node-A's cluster** (layout v2), not as a standalone single node.

**Chosen design (locked):** boot each box from a NixOS live **USB** → `disko`
formats **two disks** with **prompt-unlock** ZFS encryption → `nixos-install` the
flake. node-B = NVMe `npool` (encrypted Garage SSD) + HDD `dpool`. **node-A
differs** (Phase 1): it is ALSO a dev workstation (`modules/workstation.nix`), so
its NVMe is the **unencrypted `wpool`** dev pool and **all** of Garage lives on the
encrypted HDD `dpool` — only `dpool` is prompt-unlocked, and the box still boots
unattended. This **supersedes** the single-disk auto-unlock skeleton
(`hosts/disko-storage.nix`, which now applies only to node-C until C is
converted) for nodes A and B.

> Read order: **doc 09** (design/ADRs, the *why*) → **doc 10** (phased plan,
> layout/peering/gateway/data-plane) → **doc 12** (node-B USB mechanics in full)
> → this doc (the A→B sequence + node-A). Docs 09/10 were authored in the prod
> repo; their bare `documentations/0X-*.md` and Flux/k8s paths point there.

---

## Quickstart — the bootstrap TUI (`scripts/bootstrap-node`)

A plain-bash interactive menu drives the **workstation-side, scriptable** parts
of this runbook and prints the rest. Run it from the repo root:

```bash
./scripts/bootstrap-node
```

| Menu | Does (automated) | You still do (it prints these) |
|---|---|---|
| **1 Fleet secrets** | fleet age key; fills `.sops.yaml` recipient; generates + sops-encrypts `common.sops.yaml` (rpc/admin/metrics, **no** zfs-passphrase) — secrets never echoed | mint `tag:garage` auth keys + set the Tailscale ACL (admin console); copy the fleet age key to break-glass |
| **2 Prepare node** | per-node SSH host key → `ssh-to-age` recipient → inserts it into `.sops.yaml` → encrypts the node authkey → `sops updatekeys` | fill `hostId`/`dataDirs`/`advertiseRoutes`; confirm disk paths on the box; stage the payload USB |
| **3 Secrets** | list / `sops` edit / **verify-all-encrypted + git-stage** / `updatekeys` | `git commit && git push` the encrypted files |
| **4 Validate** | `nix flake lock` + `check` + prints the garage version | fix the 2.1.0-vs-2.3.0 pin if needed |
| **5 On-box guide** | prints the live-USB runbook for A or B (disko → install → unlock → layout) | run it **on the box** |

The script is the convenience layer; the sections below are the source of truth
(and what menu 5 prints). Everything the script can't reach — physical USB boot,
on-box `disko`/`nixos-install`/`zfs load-key`/`garage layout`, the Tailscale
console, break-glass custody — is called out as **MANUAL** here and in its output.

---

## 0. What is already done in the repo (and what you must still do)

This runbook was prepared **with the repo edits already applied** so the code and
the docs finally agree. Already committed/staged for you:

| Done | Where |
|---|---|
| Fleet-wide module options `fleet.zfsAutoUnlock / dataDirs / advertiseRoutes / sanoidDatasets` | `modules/base.nix`, `garage.nix`, `tailscale.nix`, `zfs-sanoid.nix` |
| `zfs-passphrase` sops secret gated on `zfsAutoUnlock` (not role) | `modules/sops.nix` |
| Multi-disk `data_dir` + `ConditionPathIsMountPoint` start-gate | `modules/garage.nix` |
| node-A dual-ROLE host: onsite Garage (HDD `dpool`) **+** dev workstation (NVMe `wpool`, rootless podman) | `hosts/node-a.nix`, `disko-node-a.nix`, `node-a-hardware.nix`, `modules/workstation.nix` |
| node-B dual-disk prompt-unlock host + disko + hardware (per doc 12) | `hosts/node-b.nix`, `disko-node-b.nix`, `node-b-hardware.nix` |

**Validated on real nix** (this is more than docs 11/12 could check):

- `nix eval .#nixosConfigurations.node-a` and `…node-b` **fully evaluate to a
  toplevel system derivation** once the two Phase-0 inputs below exist.
- `services.garage.settings.data_dir` renders as a **multi-disk array-of-tables**
  `[{path,capacity},…]` → confirmed both disks are used.
- Under prompt-unlock the `zfs-passphrase` secret is **absent** (good); only
  `rpc_secret / admin_token / metrics_token / tailscale-authkey` are present.
- `garage` waits for `ConditionPathIsMountPoint = [meta, data-ssd, data-hdd]`.

> ⚠️ **node-A was reworked AFTER this validation** (Phase 1 dev-workstation): its
> NVMe is now the **unencrypted `wpool`** dev pool, Garage runs a **single
> `data_dir`** on the HDD (`data-hdd`), and `ConditionPathIsMountPoint = [meta,
> data-hdd]`. **Re-run `nix flake check` for node-A.** The multi-disk `data_dir`
> facts above still describe **node-B**.

**⚠️ Two things STILL block a full build until you do them (Phase 0):**

1. **SSH keys** — `modules/base.nix` ships the `ops` + `root`
   `authorizedKeys.keys` lists **empty**. NixOS refuses to build a box with no
   login (`Neither the root account nor any wheel user has a password or SSH
   authorized key`). Paste your key(s) in §0.2.
2. **Real secrets** — only `secrets/*.sops.yaml.example` exist. You must create
   the real encrypted `secrets/common.sops.yaml` + per-node tailscale files
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
# ssh-to-age is NOT in mise — use `nix run nixpkgs#ssh-to-age -- …` (below)
```

Security invariants (from doc 09/12, do not break):

- ZFS passphrase **never** stored on the box — typed at format, re-typed at each
  unlock. Keep it offline in **two** physical locations.
- SSH host **private** key reaches the box by **direct copy** to `/mnt/etc/ssh`,
  **never** through the Nix store.
- The `garage` user gets **zero** `zfs allow` (the snapshot moat depends on it).
  The `dev` workstation user (node-A) gets **zero** `zfs allow` too.
- Fleet secrets are a **separate trust domain** — never reuse the prod cluster's
  `age137z0k…` / `age1heestk…` keys.
- Every Garage listener binds the **`tailscale0` overlay IP only**, never `0.0.0.0`.

## 0.2 Fill the SSH keys (`modules/base.nix`)

Paste your workstation SSH **public** key into both lists (replace the commented
placeholders). `ops` = break-glass admin; `root` = deploy-rs / nixos-anywhere.

```nix
  users.users.ops.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA…YOURKEY operator@workstation"
  ];
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA…YOURKEY operator@workstation"
  ];
```

**node-A only — DevPod login.** node-A also runs the dev workstation
(`modules/workstation.nix`). Paste your **Mac's** SSH public key into the `dev`
user there — DevPod connects as `dev`. Leave it empty on the other nodes.

```nix
  # modules/workstation.nix
  users.users.dev.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA…YOURMACKEY you@mac"
  ];
```

## 0.3 Mint fleet secrets (prompt-unlock variant)

```bash
./secrets/gen-secrets.sh           # prints fleet age RECIPIENT + rpc/admin/metrics
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/garage-fleet.txt"
```

Paste the printed `age1…` **recipient** into `.sops.yaml`, replacing the
`age1FLEET…` placeholder.

> **Prompt-unlock ⇒ do NOT put `zfs-passphrase` in `common.sops.yaml`.**
> `modules/sops.nix` only declares that secret when `fleet.zfsAutoUnlock = true`,
> and both node-A and node-B set it `false`. Including it would be dead, and the
> passphrase must never live on the box.

```bash
cp secrets/common.sops.yaml.example secrets/common.sops.yaml
$EDITOR secrets/common.sops.yaml      # paste rpc_secret/admin_token/metrics_token; DELETE the zfs-passphrase line
sops -e -i secrets/common.sops.yaml
```

Per-node Tailscale auth keys (mint each in the admin console: **reusable,
non-ephemeral, `tag:garage`, long/no expiry**):

```bash
for n in node-a node-b; do
  cp secrets/node-tailscale.sops.yaml.example secrets/$n-tailscale.sops.yaml
  $EDITOR secrets/$n-tailscale.sops.yaml      # paste tskey-auth-…
  sops -e -i secrets/$n-tailscale.sops.yaml
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
  echo "== $n recipient =="; nix run nixpkgs#ssh-to-age -- -i $n-extra/etc/ssh/ssh_host_ed25519_key.pub
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
  - path_regex: secrets/node-a-tailscale\.sops\.ya?ml$
    key_groups: [ { age: [ *fleet_workstation, *node_a ] } ]
  - path_regex: secrets/node-b-tailscale\.sops\.ya?ml$
    key_groups: [ { age: [ *fleet_workstation, *node_b ] } ]
```

```bash
sops updatekeys secrets/common.sops.yaml
sops updatekeys secrets/node-a-tailscale.sops.yaml
sops updatekeys secrets/node-b-tailscale.sops.yaml
sops -d secrets/common.sops.yaml >/dev/null && echo "decrypt OK"
grep -L 'sops:' secrets/*.sops.yaml || echo "all sops files encrypted"   # must print nothing but the echo
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
| `hosts/disko-node-a.nix`, `disko-node-b.nix` | NVMe/HDD `device =` paths — **confirm with `lsblk` on the live USB** before formatting. node-A: NVMe → `wpool` (dev), HDD → `dpool` (Garage) |
| `modules/workstation.nix` | node-A `dev` user SSH key (your Mac, §0.2); ARC cap if you want ≠4 GiB |
| `hosts/node-a-hardware.nix` | **defaults to the M715q module** — regenerate on the box if node-A is different hardware (see the file header) |

## 0.8 Lock + sanity-check the flake

```bash
nix flake lock                     # writes flake.lock (gitignored — fine)
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
garage-fleet/                                   # whole dir incl. encrypted secrets/*.sops.yaml
garage-fleet/node-a-extra/etc/ssh/ssh_host_ed25519_key{,.pub}
garage-fleet/node-b-extra/etc/ssh/ssh_host_ed25519_key{,.pub}
```

**Phase 0 gate:** `nix flake check` passes; `sops -d secrets/common.sops.yaml`
works; ACL saved + `tag:garage` exists + 2 authkeys minted; break-glass in 2
locations; both installer + payload USBs ready.

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
lsblk                              # CONFIRM the NVMe (boot + wpool dev) and HDD (dpool = all Garage)
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

### A.3 Partition + format (prompts for the passphrase)

```bash
nix run github:nix-community/disko -- \
  --mode destroy,format,mount --flake .#node-a --yes-wipe-all-disks
```

- **DESTROYS** the NVMe + HDD; creates ESP + ext4 root + `wpool` (unencrypted,
  dev) + `dpool` (encrypted, all Garage).
- It pauses at **`Enter passphrase:`** **once** — for `dpool/garage` only (`wpool`
  is unencrypted). This is the *only* copy — write it offline now (two locations).

```bash
zfs list                           # wpool/dev, dpool/garage/{meta,data}
ls -la /mnt/srv/garage/            # meta, data-hdd mountpoints
ls -la /mnt/home/dev               # dev workstation home on wpool
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

### A.5 First boot: join the tailnet, then fix the overlay IP

Root is unencrypted → the box boots unattended → sops decrypts (host key present)
→ tailscale auto-joins with the authkey. The `wpool` dev pool mounts immediately;
`dpool` imports but stays **locked**.

```bash
tailscale status                   # note node-A's real 100.x.y.z
zfs get keystatus dpool/garage     # unavailable (locked) — expected (wpool is unencrypted, already mounted)
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

**Phase A gate:** boots unattended; `dpool` `unavailable` until `load-key` (the
`wpool` dev pool is unencrypted and already mounted); garage inactive pre-unlock;
listeners bound to `100.x.y.z` (not `0.0.0.0`) —
`ss -tlnp | grep -E '3900|3901|3903'`; `/run/secrets/` has rpc/admin/metrics +
tailscale-authkey and **no** `zfs-passphrase`; `zfs allow dpool/garage` shows the
`garage` user **nowhere** — and the `dev` user **nowhere** either (the workstation
must not reach the moat); `data-hdd` used (single `data_dir`); `sanoid.timer`
active.

### A.9 Verify the dev workstation (node-A dual-role)

node-A also hosts your devcontainers — rootless podman, driven from the Mac via
DevPod. Independent of Garage: it works the moment the box is up; the encrypted
`dpool` does **not** need unlocking for dev work.

On node-A:

```bash
sudo -u dev podman info | grep -A2 graphDriver    # expect overlay + fuse-overlayfs (NOT vfs)
sudo -u dev XDG_RUNTIME_DIR=/run/user/2000 systemctl --user status podman.socket   # active (listening)
zfs allow dpool/garage                            # the dev user must appear NOWHERE
```

From the **Mac** (after pasting your key into the `dev` user, §0.2):

```bash
devpod provider add ssh --option HOST=dev@node-a.<tailnet>.ts.net
devpod up <repo> --provider ssh --ide vscode
```

`DOCKER_HOST` is forced server-side (sshd `Match User dev` → `SetEnv`), so the
remote build just works. Rootless limits: no `--privileged`, no docker-in-docker,
no host ports <1024. ZFS ARC is capped at 4 GiB to leave RAM for containers.

**Phase A (workstation) gate:** `podman info` shows the `overlay` driver;
`devpod up` builds and the IDE attaches; `dpool` can stay locked and dev still
works; `zfs allow dpool/garage` lists neither `garage` nor `dev`.

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
nix run github:serokell/deploy-rs -- .#node-a --remote-build
nix run github:serokell/deploy-rs -- .#node-b --remote-build
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
ssh ops@node-b.<tailnet>.ts.net
sudo zfs load-key -a && sudo zfs mount -a
sudo systemctl start garage
```

On **node-A** the dev workstation (`wpool`, rootless podman) is already up at this
point — only Garage waits for the `dpool` unlock above.

Never store the passphrase on the box (that defeats prompt-unlock). For the
onsite node-A you *may* opt `dpool` into auto-unlock, but note (post Phase 1) that
flipping `fleet.zfsAutoUnlock = true` **alone is not enough** — you must also
switch `dpool/garage` `keylocation` to a `file://…` URL in
`hosts/disko-node-a.nix` and add a boot load-key unit (doc 12 §9(a)), accepting
the weaker theft story. node-A's `wpool` (dev) is already unencrypted and always
auto-mounts.

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
- `hosts/node-a.nix` + `disko-node-a.nix` + `node-a-hardware.nix` — node-A on the
  prompt-unlock model (onsite, non-proxy), **reworked for the dev-workstation
  dual-role** (Phase 1): NVMe = unencrypted `wpool` (dev), all Garage on the
  encrypted HDD `dpool` (single `data_dir`).
- `modules/workstation.nix` — **new** (Phase 1, node-A only): rootless-podman
  devcontainer host for DevPod — unprivileged `dev` user (no wheel/docker/
  zfs-allow), pinned uid 2000, `DOCKER_HOST` + agent-forwarding-off via sshd
  `Match User dev`, ZFS ARC cap. Co-located with the DR Garage role.
- `hosts/node-b.nix` + `disko-node-b.nix` + `node-b-hardware.nix` — **new/rewritten**
  per doc 12.
- `hosts/node-c.nix` / `node-d.nix` — **unchanged**. node-C still imports the
  single-disk `disko-storage.nix`; convert it to the dual-disk model (copy
  node-A's HDD-`dpool` Garage layout) when you install it, or keep single-disk per
  its hardware.
