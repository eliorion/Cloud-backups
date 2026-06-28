# garage-fleet — standalone NixOS fleet for the Garage backup cluster

A 4-node, geo-distributed, ransomware-resistant **Garage** S3 object store on
**NixOS + ZFS**, deployed with **disko + nixos-anywhere + deploy-rs + sops-nix**.
It is the durable DR target for the prod Talos cluster (etcd snapshots, CNPG
Postgres PITR, selected Longhorn PVCs).

This repo is a **SEPARATE TRUST DOMAIN** from the prod cluster (different OS,
identities, network posture, control plane) — that separation is the whole point
(doc 09 §2, ADR-1). It is **not** joined to prod and **not** a second Kubernetes
cluster.

**Authoritative design + plan** (in the prod repo):

- `documentations/09-garage-backup-cluster.md` — design + decision records (the *why*).
- `documentations/10-garage-backup-implementation-plan.md` — phased runbook (the *how*).

Read those first. This README is the fleet-side quickstart only. The whole node
lifecycle is driven by one tool — **`scripts/fleet`** (see Quickstart below).

---

## Layout

```
garage-fleet/
  scripts/fleet             # ONE entrypoint: new / install / deploy / status (this doc)
  flake.nix                 # inputs; a `hosts` attrset derives nixosConfigurations
                            #   (+ per-node `-install` variants) and the deploy-rs map
  .sops.yaml                # FLEET recipients (separate from the prod cluster's)
  private-keys/             # gitignored: fleet age key + per-node SSH host keys
  secrets/
    gen-secrets.sh                      # (legacy) manual fleet-key + token minting
    common.sops.yaml.example            # TEMPLATE: rpc_secret + admin/metrics tokens
    node-tailscale.sops.yaml.example    # TEMPLATE: per-node tag:garage auth key
  modules/
    base.nix        # ssh hardening, nftables firewall, users, boot gens, nix
    sops.nix        # sops-nix wiring (age from SSH host key), secret entries
    garage.nix      # services.garage + garage.toml, listeners on the tailnet
    zfs-sanoid.nix  # ZFS + sanoid RO snapshot moat + autoScrub (storage nodes)
    tailscale.nix   # services.tailscale, authkey, tags, proxy toggle
    workstation.nix # node-A ONLY: rootless-podman DevPod host (unprivileged dev user)
  hosts/
    node-a.nix      # onsite   storage + workstation
    node-b.nix      # offsite-1 storage + proxy
    node-c.nix      # offsite-2 storage + proxy
    node-d.nix      # gateway  (capacity 0, no data, no zone)
    disko-node-a.nix   # node-A: unencrypted NVMe wpool (dev) + encrypted HDD dpool
    disko-node-b.nix   # node-B: encrypted NVMe npool + encrypted HDD dpool
    disko-storage.nix  # node-C: single encrypted ZFS pool
    disko-gateway.nix  # simple boot+root, no data pool (greenfield D rebuild only)
```

Each storage host imports its disko file + `zfs-sanoid` + (via the flake)
`garage` + `tailscale`; node-A also imports `workstation.nix`. The gateway
imports no disko and no `zfs-sanoid`.

---

## ⚠️ `nix flake lock` — operator must run it

**No `flake.lock` is committed** and **nix is not available** in the environment
this repo was generated in. Before anything else, on a workstation with nix
(flakes enabled):

```bash
cd garage-fleet
nix flake lock      # resolves nixpkgs/disko/sops-nix/deploy-rs to flake.lock
nix flake check     # evaluates configs + runs deploy-rs schema checks
```

Commit the resulting `flake.lock`. Renovate then keeps the inputs current.

---

## Quickstart — `scripts/fleet`

`scripts/fleet` is the single workstation entrypoint for the node lifecycle (it
replaced the old `bootstrap-node` + `deploy-node`). Run it bare for a TUI, or:

```bash
./scripts/fleet                                    # TUI menu (status + actions)
./scripts/fleet new    node-a                      # §0: secrets + scaffold (idempotent; --force regens)
./scripts/fleet config tailnet <name>              # set the deploy MagicDNS tailnet
./scripts/fleet secrets                            # verify-all-encrypted + git add; then git commit
./scripts/fleet install node-a root@<installer-ip> # §1: remote provision (nixos-anywhere)
./scripts/fleet deploy  node-a                     # §2: apply a config change (deploy-rs + auto-rollback)
./scripts/fleet status                             # readiness + lifecycle state per node
```

`new`/`secrets`/`status` run in the devcontainer (sops + age, **no nix**);
`install`/`deploy` need **nix** — run them from a nix host. Without `--force`,
`new` skips whatever already exists. Sections 0–2 below are what these commands
do under the hood (and the console fallback).

---

## 0. Secret bootstrap (doc 10 Phase 0)

`./scripts/fleet new <node>` does all of the below — idempotently — minting the
fleet age key, the shared secrets, the node's SSH host key (→ `private-keys/`),
its `ssh-to-age` recipient (→ `.sops.yaml`), the Tailscale authkey, and
`sops updatekeys`. The manual equivalent:

```bash
cd garage-fleet
./secrets/gen-secrets.sh
```

This mints the **fleet** age keypair (a separate trust domain — never the prod
`age137z0k…`/`age1heestk…` keys), prints the **recipient** to paste into
`.sops.yaml`, and prints fresh `rpc_secret` / `admin_token` / `metrics_token`.
Then:

1. Paste the printed recipient into `.sops.yaml` (replace every `age1FLEET…`).
2. `cp secrets/common.sops.yaml.example secrets/common.sops.yaml`, fill the
   three values, `sops -e -i secrets/common.sops.yaml`.
3. Mint a reusable, non-ephemeral, **tag:garage** auth key in the Tailscale
   admin console; `cp secrets/node-tailscale.sops.yaml.example
   secrets/<node>-tailscale.sops.yaml` per node, paste the key, `sops -e -i`.
4. **Break-glass:** copy the fleet age **private** key, the ZFS passphrase, and
   the restic/Kopia/age repo passwords offline to **two physical locations**
   (doc 09 §8). These are catastrophic-loss; the ZFS key is unrecoverable from a
   lost node fleet.

Set the **Tailscale ACL** (deny-by-default, doc 09 §3): `tag:garage ↔ tag:garage`
on `3900,3901,3903`; `tag:k8s → tag:garage` on **`tcp:3900` only** (never RPC
`3901`, never admin `3903`).

---

## 1. Provision (disko + nixos-anywhere) — doc 10 Phase 1/2

Boot each new node (A/B/C) into a NixOS live/installer image with SSH-as-root, then:

```bash
./scripts/fleet install node-a root@<installer-ip>
```

`fleet install` prompts for the ZFS passphrase, uploads it to the installer's RAM
only (`--disk-encryption-keys`, a tmpfs file — never written to disk), seeds the
SSH host key (`--extra-files`), runs nixos-anywhere against the `.#node-a-install`
variant, then restores `keylocation=prompt` post-boot over `ssh`. In effect:

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#node-a-install \
  --disk-encryption-keys /tmp/fleet-zfs.key <passphrase-tmpfile> \
  --extra-files <hostkey-tree> \   # seeds /etc/ssh/ssh_host_ed25519_key
  root@<installer-ip>
# extra args pass through after `--`, e.g.:
#   ./scripts/fleet install node-a root@<ip> -- --generate-hardware-config nixos-generate-config hosts/node-a-hardware.nix
```

`fleet new` already added the node's `ssh-to-age` recipient to `.sops.yaml` and
re-encrypted the shared secrets, so the box can decrypt at activation (doc 09 §8)
— just commit before installing (a flake copies only git-tracked files). Then
bring up the Garage layout imperatively (`garage layout assign … -z <zone>
-c <bytes>`, `garage layout apply --version <prev+1>` — exactly `prev+1`, once;
doc 09 §5; `fleet guide <node>` prints the exact commands).

**node-D is already in production** — reconfigure it **additively** (doc 10
Phase 3): do **not** import `disko-gateway.nix` in place, add only
`services.garage` (fleet.role=gateway). `garage layout assign <id-D> --gateway`.

---

## 2. Deploy (deploy-rs, magic rollback) — doc 09 ADR-4

```bash
./scripts/fleet deploy node-a    # runs: nix run github:serokell/deploy-rs -- .#node-a
./scripts/fleet rollback node-a  # escape hatch: switch the box to its previous generation
```

deploy-rs **magic rollback** auto-reverts a bad `tailscaled`/firewall change on a
remote offsite node within ~30s. Caveats (doc 09 ADR-4): magic rollback only
protects once a *prior* generation was also deployed by deploy-rs — do the first
post-install deploy with console / initrd-SSH fallback available; and configure
per-host SSH identities in `~/.ssh/config` keyed by the Tailscale MagicDNS name
(neither deploy-rs nor colmena handle per-host/passphrase keys themselves).

---

## Per-host placeholders to fill (search for `TODO operator:`)

| Where | Placeholder |
|---|---|
| `flake.nix` | `<tailnet>` MagicDNS name — set with `./scripts/fleet config tailnet <name>` |
| `.sops.yaml` | fleet recipient `age1FLEET…`; each node's `ssh-to-age` recipient after install |
| `modules/base.nix` | `ops` + `root` SSH authorized keys; `system.stateVersion` |
| `modules/garage.nix` | `package = pkgs.garage_2` attr name on your nixpkgs; `bootstrap_peers` (peer pubkey@overlay:3901) |
| `modules/tailscale.nix` | proxy `--advertise-routes=…` for B/C |
| `hosts/disko-storage.nix` | boot/data disk device paths; zpool `mode`; offsite `keylocation=prompt` opt-in |
| `hosts/disko-gateway.nix` | node-D OS disk device (greenfield only) |
| `hosts/node-a/-b/-c/-d.nix` | `tailscaleIp` (overlay IP), `hostId` (unique 8-hex), per-node hardware import; Garage `-c <bytes>` capacity at layout time |

Node summary:

| Host | Zone | Role | Garage capacity | ZFS pool + sanoid | Proxy |
|---|---|---|---|---|---|
| node-a | onsite | storage | non-zero (`-c <bytes>`) | yes | no |
| node-b | offsite-1 | storage | non-zero | yes | yes |
| node-c | offsite-2 | storage | non-zero | yes | yes |
| node-d | (none) | gateway | **0 / `--gateway`** | no | (existing prod role) |

---

## Notes

- **Garage version** is pinned to **v2.3.0** (via the nixpkgs input + the
  `services.garage.package` attr); Renovate-tracked (doc 10 Phase 8).
- **Garage has no Object Lock and no S3 versioning (v2.3.0)** — immutability is
  the **ZFS snapshot moat** (`modules/zfs-sanoid.nix`), not any Garage feature.
  The `garage` user must hold **no** `zfs allow` on `bpool/garage`; audit with
  `zfs allow bpool/garage` (doc 09 §7, doc 10 Phase 5).
- All Garage listeners (`3900/3901/3903`) bind the node's `tailscale0` overlay
  IP only; the host firewall trusts only `tailscale0` (doc 09 §3).
- The data-plane backup *jobs* (etcd CronJob, CNPG ObjectStore, Velero) live in
  the **prod repo** under Flux, not here.
