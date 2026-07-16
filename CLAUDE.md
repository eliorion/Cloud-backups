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
- `flake.nix` — inputs (incl. `lanzaboote` v0.4.2 for node-A Secure Boot);
  `specialArgs` passes `inputs` so `secureboot.nix` can import the lanzaboote module.
  A `hosts` attrset DERIVES `nixosConfigurations` (+ a per-node `-install` variant each)
  and the `deploy-rs` node map. `node-d` is commented out of `hosts` until its
  hardware-config is wired (else `nix flake check` fails)
- `modules/` — `base.nix` (ssh/nftables/`sysadmin`+root users/nix; `fleet.*` options),
  `sops.nix` (sops-nix wiring), `garage.nix` (`services.garage` + garage.toml, tailnet
  listeners), `zfs-sanoid.nix` (ZFS + sanoid RO snapshot moat + autoScrub),
  `tailscale.nix`, `secureboot.nix` (node-A ONLY: lanzaboote signed UKIs + systemd
  stage-1 initrd + TPM2 LUKS unlock + the on-box enrollment runbook; gated on
  `fleet.secureBoot`), `workstation.nix` (node-A ONLY: ROOT-docker devcontainer host
  for DevPod — `sysadmin` in the `docker` group, ARC cap, docker data-root on
  `wpool/docker`. ⚠️ The docker group is root-equivalent, so node-A's ZFS moat is
  **deliberately forfeited** — B and C hold the real moat and must never take this role)
- `hosts/` — `node-a/-b/-c/-d.nix`; `disko-node-a.nix` (A: **two trust domains** —
  NVMe = ESP + swap + LUKS2 `cryptwork` (TPM2/PCR-7 auto-unlock) → ZFS-root `wpool`
  {root, sysadmin home, docker}; encrypted HDD `dpool` = ALL of Garage,
  prompt-unlock over the mesh. Root is a `wpool` dataset, not a fixed partition),
  `disko-node-b.nix` (B: **unencrypted** ext4 root + encrypted npool + dpool),
  `disko-storage.nix` (C: unencrypted root + single encrypted pool), `disko-gateway.nix`
  (boot+root only, greenfield D rebuild). ZFS-native encrypted datasets use
  `keylocation=prompt` at runtime, `file://${fleet.zfsInstallKeyfile}` only under the
  `-install` variant; node-A's LUKS root additionally reads `fleet.luksInstallKeyfile`
  at install (its own passphrase, node-A only).
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
  nixos-anywhere + transient tmpfs passphrase feed → restores prompt-unlock; node-A
  prompts for TWO passphrases — see below), `fleet deploy <node>` (deploy-rs),
  `fleet finalize <node> root@host` (retry the post-install dpool unlock),
  `fleet config tailnet <name>` (slug only — `.ts.net` is appended), `fleet secrets`,
  `fleet status`. ALL of these now need nix — sops/age come from the flake's
  **purego** builds (`nix run .#sops`/`.#age`), never a stock/mise binary (see the
  Rosetta note below).
- **deploy-rs, not Flux** (`fleet deploy <node>` wraps it): `nix run .#deploy-rs -- .#node-a`. Magic
  rollback auto-reverts a bad firewall/tailscaled change in ~30s, but only once a
  *prior* generation was also deploy-rs-deployed — do the first post-install
  deploy with console / initrd-SSH fallback. Per-host SSH identities go in
  `~/.ssh/config` keyed by the Tailscale MagicDNS name.
- **Provision** with disko + nixos-anywhere (`fleet install <node> root@host` wraps
  this against the `.#<node>-install` variant) (`--flake .#node-a`,
  `--disk-encryption-keys`, `--generate-hardware-config`). `--extra-files` seeds
  BOTH the SSH host key AND the node's **dedicated age key** to
  `/var/lib/sops-nix/key.txt` (`modules/sops.nix` `age.keyFile`) — WITHOUT the age
  key, first-boot activation can't decrypt any secret and `switch` fails. `fleet
  new <node>` mints that key (`private-keys/<node>-age.txt`) and writes its
  recipient into `.sops.yaml`, so the recipient is set BEFORE install, not after.
  (This replaced the old ssh-to-age-derived identity, which could not decrypt at
  boot.)
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
- ⚠️ **sops/age MUST be the flake's `-tags=purego` builds** (`nix run .#sops`/`.#age`,
  `mise run sops`, or `nix develop`) — NEVER a stock or mise-installed binary. This
  devcontainer is x86_64 **emulated under Rosetta on an Apple-Silicon Mac**
  (`/proc/cpuinfo` model name `VirtualApple`), and Rosetta mis-translates Go's asm
  ChaCha20-Poly1305, so a stock sops/age SILENTLY produces corrupt age ciphertext:
  it decrypts on the workstation but no real node can (`sops-install-secrets` fails
  `0 successful groups required, got 0`, starving garage/tailscale). `flake.nix`
  `withPurego` builds the Rosetta-safe variants; `scripts/fleet`, `mise.toml`, and
  `secrets/gen-secrets.sh` all route through them. X25519 and AES-GCM survive
  Rosetta — only ChaCha20-Poly1305 asm is wrong; the nodes' own AMD CPUs are fine.
- **Per-node identity = a DEDICATED age key**, `private-keys/<node>-age.txt`
  (gitignored, break-glass), whose recipient is in `.sops.yaml` and whose private
  half `fleet install` seeds to `/var/lib/sops-nix/key.txt` (`modules/sops.nix`
  `age.keyFile`; `age.sshKeyPaths = mkForce []`). This REPLACED deriving the identity
  from the SSH host key via ssh-to-age (which sops-nix's bundled ssh-to-age could
  not decrypt at boot). The SSH host key is now only the node's SSH host identity.
- **Secrets layout** — `common.enc.yaml` = ONLY fleet-identical values
  (`rpc_secret`/`admin_token`/`metrics_token`), encrypted to every node.
  `<node>.enc.yaml` = everything node-specific (`authkey`, `root_password_hash`),
  encrypted to that node + workstation ONLY, so a compromised node cannot read any
  other node's. `modules/sops.nix` DERIVES the per-node file from
  `networking.hostName` — never wire `sopsFile` per host. A missing key fails at
  BUILD time (sops-nix validates the manifest), so it cannot brick a node.
  Edit with `sops edit` — `sops decrypt > file.yaml` leaves plaintext in the tree
  (`.gitignore` denies `secrets/*.yaml`, but do not rely on it).
- **Never put `zfs-passphrase` in ANY sops file.** The node's age key (a DEDICATED
  age identity, `private-keys/<node>-age.txt`, seeded to `/var/lib/sops-nix/key.txt`)
  lives on the root (unencrypted ext4 on B/C; on node-A the root is LUKS/TPM but is
  auto-unlocked at runtime, so a powered-on stolen box still exposes it), and
  `<node>.enc.yaml` ships to the node — so a stored passphrase means a stolen box
  unlocks its own backups, while you still type it at every reboot (worst of both). Keep it OFFLINE (password manager + a second physical copy); typed at
  `fleet install` and each unlock. `keylocation=prompt` has **no recovery path**.
  Same for per-node root passwords: only the `$6$` hash goes in sops, the plaintext
  lives in the password manager.
- **node-A boot model (LUKS/TPM/Secure Boot) — node-A ONLY.** Two trust domains:
  the NVMe (root + sysadmin home + docker) is a LUKS2 `cryptwork` container unsealed
  UNATTENDED in initrd by a TPM2 keyslot bound to PCR 7 (`modules/secureboot.nix`),
  so the box boots + rejoins the tailnet with no operator; the HDD `dpool` (all of
  Garage) is the MANUAL gate, unlocked over the mesh. Secure Boot (lanzaboote signed
  UKIs) is STAGED behind `fleet.secureBoot` (default **false** — install and the
  first deploy MUST use systemd-boot because lanzaboote signs against keys that only
  exist after the on-box `sbctl create-keys`; flip true and deploy only once the keys
  exist; then enroll + enable Secure Boot + `systemd-cryptenroll` the TPM — order is
  load-bearing, see the secureboot.nix runbook). **node-A therefore has TWO install
  passphrases** (both prompted by `fleet install`, both → password manager): the
  `dpool` ZFS passphrase (manual gate, typed each unlock) AND the `cryptwork` LUKS
  recovery passphrase (keyslot-0, the only way back when a firmware/kernel update
  rotates PCR 7). **node-B/-C have ONE** — their root is unencrypted ext4 (no LUKS
  domain), so the only human-held secret is the ZFS data passphrase. Passphrase count
  = number of encryption domains needing a human-held secret. Enrollment needs a
  PHYSICAL firmware trip (setup mode + supervisor password); can't be done over SSH.
- ⚠️ **The fleet age key (`private-keys/garage-fleet.txt`) must NEVER land on
  node-A.** It decrypts EVERY node's secrets. node-A is the DevPod devcontainer
  host and runs arbitrary third-party code as effective root (`docker` group,
  `modules/workstation.nix`), so copying the key there to "run fleet locally"
  hands the whole fleet to anything that escapes a container — and collapses the
  per-node isolation above. Run `scripts/fleet` from the workstation devcontainer
  only; node-A is for dev work. Keep a break-glass copy in the password manager,
  never in the repo (`private-keys/` is gitignored and CANNOT be regenerated —
  `fleet` refuses, since a new key cannot decrypt existing secrets).
- **`flake.lock` MUST be committed** — same rule as `secrets/*.enc.yaml`: a flake's
  source is its git-tracked files, so a gitignored lock is invisible to nix, which
  then re-resolves every input to upstream HEAD on each command and pins nothing.
  Renovate tracks inputs. `nixos-anywhere` is an input too (`nix run .#nixos-anywhere`
  in `scripts/fleet install`) — the tool that formats disks must not float.

## Verify changes

The devcontainer ships nix (single-user, no daemon, flakes enabled — see
`.devcontainer/Dockerfile`), so these run here:

```bash
nix develop         # operator toolchain: sops/age (PUREGO — Rosetta-safe),
                    # ssh-to-age/openssl/openssh/git + deploy-rs, pinned by flake.lock
nix flake lock      # resolves nixpkgs/disko/sops-nix/deploy-rs/nixos-anywhere/lanzaboote
nix flake check     # evaluates all nixosConfigurations + deploy-rs schema checks
```

`fleet install`/`deploy` from the devcontainer reach LAN targets fine, but the
container has no `tailscale` and no `/dev/net/tun` — offsite nodes on the tailnet
need userspace tailscaled + an ssh `ProxyCommand`, `--device=/dev/net/tun`
+ `--cap-add=NET_ADMIN` in `devcontainer.json`, or running `fleet` from the host.
