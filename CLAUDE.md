# garage-fleet — standalone NixOS fleet for the Garage backup cluster

A 4-node, geo-distributed, ransomware-resistant **Garage** S3 object store on
**NixOS + ZFS**, deployed with **disko + nixos-anywhere + deploy-rs + sops-nix**.
It is the durable DR target for the prod Talos cluster (etcd snapshots, CNPG
Postgres PITR, selected Longhorn PVCs).

This repo is a **SEPARATE TRUST DOMAIN** from the prod cluster (different OS,
identities, network posture, control plane). It is **not** joined to prod and
**not** a second Kubernetes cluster — there is no Flux, no kubectl, no Talos
here. The data-plane backup *jobs* (etcd CronJob, CNPG ObjectStore, Velero) live
in the **prod repo** (`k3sclusterforlearning`) under Flux, not here.

**Authoritative design + plan** (read first):

- `documentations/09-garage-backup-cluster.md` — design + decision records (the *why*).
- `documentations/10-garage-backup-implementation-plan.md` — phased runbook (the *how*).
- `documentations/11-node-b-image-flash.md`, `12-node-b-usb-install.md` — node provisioning.

> Docs 09/10 were authored in the prod repo and bundled here; their bare
> `documentations/0X-*.md` references and Flux/k8s paths point at the prod repo,
> not this one.

## Repo layout

- `flake.nix` — inputs + `nixosConfigurations` (node-a/b/c/d) + `deploy-rs` node map
- `modules/` — `base.nix` (ssh/nftables/users/nix), `sops.nix` (sops-nix wiring),
  `garage.nix` (`services.garage` + garage.toml, tailnet listeners),
  `zfs-sanoid.nix` (ZFS + sanoid RO snapshot moat + autoScrub), `tailscale.nix`
- `hosts/` — `node-a/-b/-c/-d.nix`, `disko-storage.nix` (encrypted ZFS pool, A/B/C),
  `disko-gateway.nix` (boot+root only, greenfield D rebuild)
- `secrets/` — `gen-secrets.sh`, `common.sops.yaml.example`,
  `node-tailscale.sops.yaml.example`
- `.sops.yaml` — **FLEET** age recipients (separate trust domain from prod)

Node roles: `node-a` onsite storage; `node-b` offsite-1 storage+proxy; `node-c`
offsite-2 storage+proxy; `node-d` gateway (capacity 0, no data/zone). **node-D is
already in production** — reconfigure it **additively** (do not import
`disko-gateway.nix` in place); see doc 10 Phase 3.

## Conventions

- **deploy-rs, not Flux**: `nix run github:serokell/deploy-rs -- .#node-a`. Magic
  rollback auto-reverts a bad firewall/tailscaled change in ~30s, but only once a
  *prior* generation was also deploy-rs-deployed — do the first post-install
  deploy with console / initrd-SSH fallback. Per-host SSH identities go in
  `~/.ssh/config` keyed by the Tailscale MagicDNS name.
- **Provision** with disko + nixos-anywhere (`--flake .#node-a`,
  `--disk-encryption-keys`, `--extra-files` seeds the SSH host key,
  `--generate-hardware-config`). After install, **add that node's `ssh-to-age`
  recipient to `.sops.yaml` and re-encrypt the shared secrets before the first
  `deploy-rs` push** — else activation can't decrypt and `switch` fails.
- **Garage layout** is imperative: `garage layout assign … -z <zone> -c <bytes>`,
  then `garage layout apply --version <prev+1>` — exactly `prev+1`, once.
- **Garage `v2.3.0`** is pinned (nixpkgs input + `services.garage.package`),
  Renovate-tracked. v2.3.0 has **no Object Lock and no S3 versioning** —
  immutability is the **ZFS snapshot moat** (`modules/zfs-sanoid.nix`), not a
  Garage feature. The `garage` user must hold **no** `zfs allow` on the data pool.
- All Garage listeners (`3900` S3 / `3901` RPC / `3903` admin) bind the node's
  `tailscale0` overlay IP only; the host firewall trusts only `tailscale0`.
  Tailscale ACL is deny-by-default: `tag:garage ↔ tag:garage` on `3900,3901,3903`;
  `tag:k8s → tag:garage` on **`tcp:3900` only** (never RPC `3901`, never admin `3903`).
- Secrets: SOPS whole-file encryption (flat key/value for sops-nix, not k8s
  Secrets — no `encrypted_regex`). Use **FLEET** age recipients only — never reuse
  the prod cluster's `age137z0k…`/`age1heestk…` keys. Real `secrets/*.sops.yaml`
  **must be committed** (a flake copies only git-tracked files into the store, so a
  gitignored secret is invisible to sops-nix activation). Verify each is encrypted
  before committing (`grep -L 'sops:' secrets/*.sops.yaml` returns nothing). Never
  commit plaintext secrets or the ZFS/age private keys.
- **No `flake.lock` is committed** — the operator runs `nix flake lock` on a nix
  workstation; Renovate tracks inputs afterward.

## Verify changes

`nix` is not available in the repo-generation environment — run these on a
workstation with nix (flakes enabled):

```bash
nix flake lock      # first time only: resolves nixpkgs/disko/sops-nix/deploy-rs
nix flake check     # evaluates all nixosConfigurations + deploy-rs schema checks
```
