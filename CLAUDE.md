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

- `scripts/fleet` — **single workstation entrypoint** for the node lifecycle
  (`new`/`install`/`deploy`/`rollback`/`status`/`secrets`/`config`); replaced the
  former `bootstrap-node` + `deploy-node`. `private-keys/` (gitignored) holds the
  fleet age key + per-node SSH host keys; `.fleet/` (gitignored) holds deploy markers.
- `flake.nix` — inputs; a `hosts` attrset DERIVES `nixosConfigurations` (+ a per-node
  `-install` variant each) and the `deploy-rs` node map. `node-d` is commented out of
  `hosts` until its hardware-config is wired (else `nix flake check` fails)
- `modules/` — `base.nix` (ssh/nftables/users/nix), `sops.nix` (sops-nix wiring),
  `garage.nix` (`services.garage` + garage.toml, tailnet listeners),
  `zfs-sanoid.nix` (ZFS + sanoid RO snapshot moat + autoScrub), `tailscale.nix`,
  `workstation.nix` (node-A ONLY: ROOT-docker devcontainer host for DevPod — `dev`
  user in the `docker` group, ARC cap, docker data-root on `wpool/docker`.
  ⚠️ The docker group is root-equivalent, so node-A's ZFS moat is **deliberately
  forfeited** — B and C hold the real moat and must never take this role)
- `hosts/` — `node-a/-b/-c/-d.nix`; `disko-node-a.nix` (A: unencrypted NVMe wpool +
  encrypted HDD dpool), `disko-node-b.nix` (B: encrypted npool + dpool),
  `disko-storage.nix` (C: single encrypted pool), `disko-gateway.nix` (boot+root
  only, greenfield D rebuild). Encrypted datasets use `keylocation=prompt` at
  runtime, `file://${fleet.zfsInstallKeyfile}` only under the `-install` variant.
- `secrets/` — `gen-secrets.sh`, `common.enc.yaml.example`,
  `node.enc.yaml.example`
- `.sops.yaml` — **FLEET** age recipients (separate trust domain from prod)

Node roles: `node-a` onsite storage; `node-b` offsite-1 storage+proxy; `node-c`
offsite-2 storage+proxy; `node-d` gateway (capacity 0, no data/zone). **node-D is
already in production** — reconfigure it **additively** (do not import
`disko-gateway.nix` in place); see doc 10 Phase 3.

## Conventions

- **Use `scripts/fleet`** for routine work: `fleet new <node>` (secrets + scaffold,
  idempotent, `--force` regens), `fleet install <node> root@host` (remote
  nixos-anywhere + transient tmpfs ZFS-passphrase feed → restores prompt-unlock),
  `fleet deploy <node>` (deploy-rs), `fleet config tailnet <name>`, `fleet secrets`,
  `fleet status`. `new`/`secrets` need sops+age (no nix); `install`/`deploy` need nix.
- **deploy-rs, not Flux** (`fleet deploy <node>` wraps it): `nix run .#deploy-rs -- .#node-a`. Magic
  rollback auto-reverts a bad firewall/tailscaled change in ~30s, but only once a
  *prior* generation was also deploy-rs-deployed — do the first post-install
  deploy with console / initrd-SSH fallback. Per-host SSH identities go in
  `~/.ssh/config` keyed by the Tailscale MagicDNS name.
- **Provision** with disko + nixos-anywhere (`fleet install <node> root@host` wraps
  this against the `.#<node>-install` variant) (`--flake .#node-a`,
  `--disk-encryption-keys`, `--extra-files` seeds the SSH host key,
  `--generate-hardware-config`). After install, **add that node's `ssh-to-age`
  recipient to `.sops.yaml` and re-encrypt the shared secrets before the first
  `deploy-rs` push** — else activation can't decrypt and `switch` fails.
- **Garage layout** is imperative: `garage layout assign … -z <zone> -c <bytes>`,
  then `garage layout apply --version <prev+1>` — exactly `prev+1`, once.
- **Garage version**: design target is `v2.3.0` (docs 09/10), but what actually
  deploys is **`2.1.0`** — nixpkgs `nixos-25.05` has no `garage_2_3_0` attr
  (newest is `garage_2_1_0`), so `pkgs.garage_2` resolves to 2.1.0. To really get
  2.3.0, bump the nixpkgs input or add an overlay (doc 13). Renovate tracks the
  input. Verify, never assume:
  `nix eval --raw .#nixosConfigurations.node-a.config.services.garage.package.version`
- **Neither 2.1.0 nor 2.3.0 has Object Lock or S3 versioning** — immutability is
  the **ZFS snapshot moat** (`modules/zfs-sanoid.nix`), not a Garage feature. The
  `garage` user must hold **no** `zfs allow` on the data pool.
- All Garage listeners (`3900` S3 / `3901` RPC / `3903` admin) bind the node's
  `tailscale0` overlay IP only; the host firewall trusts only `tailscale0`.
  Tailscale ACL is deny-by-default: `tag:garage ↔ tag:garage` on `3900,3901,3903`;
  `tag:k8s → tag:garage` on **`tcp:3900` only** (never RPC `3901`, never admin `3903`).
- Secrets: SOPS whole-file encryption (flat key/value for sops-nix, not k8s
  Secrets — no `encrypted_regex`). Use **FLEET** age recipients only — never reuse
  the prod cluster's `age137z0k…`/`age1heestk…` keys. Real `secrets/*.enc.yaml`
  **must be committed** (a flake copies only git-tracked files into the store, so a
  gitignored secret is invisible to sops-nix activation). Verify each is encrypted
  before committing (`grep -L 'sops:' secrets/*.enc.yaml` returns nothing). Never
  commit plaintext secrets or the ZFS/age private keys.
- **`flake.lock` MUST be committed** — same rule as `secrets/*.enc.yaml`: a flake's
  source is its git-tracked files, so a gitignored lock is invisible to nix, which
  then re-resolves every input to upstream HEAD on each command and pins nothing.
  Renovate tracks inputs. `nixos-anywhere` is an input too (`nix run .#nixos-anywhere`
  in `scripts/fleet install`) — the tool that formats disks must not float.

## Verify changes

The devcontainer ships nix (single-user, no daemon, flakes enabled — see
`.devcontainer/Dockerfile`), so these run here:

```bash
nix develop         # operator toolchain: sops/age/ssh-to-age/openssl/openssh/git
                    # + deploy-rs, all pinned by flake.lock (flake.nix devShells)
nix flake lock      # first time only: resolves nixpkgs/disko/sops-nix/deploy-rs
nix flake check     # evaluates all nixosConfigurations + deploy-rs schema checks
```

`fleet install`/`deploy` from the devcontainer reach LAN targets fine, but the
container has no `tailscale` and no `/dev/net/tun` — offsite nodes on the tailnet
need userspace tailscaled + an ssh `ProxyCommand`, `--device=/dev/net/tun`
+ `--cap-add=NET_ADMIN` in `devcontainer.json`, or running `fleet` from the host.
