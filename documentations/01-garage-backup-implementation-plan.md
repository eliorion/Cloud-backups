# Garage backup cluster — phased implementation plan

Build the architecture from `documentations/00-garage-backup-cluster.md`: a
4-node, geo-distributed, self-hosted **Garage** S3 cluster (NixOS + ZFS) that
serves as the ransomware-resistant DR target for the Talos prod cluster (etcd
snapshots, CNPG Postgres PITR, selected Longhorn PVCs). This is the **runbook** —
ordered phases, each with objective, prerequisites, tasks, the exact IaC
artifacts to create, a verification gate, and a rollback. Read 09 first for the
*why*; read `documentations/03-backups.md` for the CNPG→object-store mechanics
this plan **extends, not re-explains**.

> ⚠️ This plan touches two repositories:
> - **the prod repo** (`k3sclusterforlearning`) — Flux-managed data-plane backup jobs.
> - **this repo** `garage-fleet` (NixOS fleet) — the 4 storage/gateway nodes.
> Paths below are tagged `[k8s]` (the prod repo) or `[fleet]` (this repo). This doc
> was authored in the prod repo and bundled here, so bare `documentations/0X-*.md`
> references (`03-backups.md`, `05-alerting.md`, `07-talos-ha-expansion.md`) live in
> the prod repo, not here.

## Current state

| Node | Zone | Role | Status |
|---|---|---|---|
| `node-A` | `onsite` | storage | **not installed** |
| `node-B` | `offsite-1` | storage + Tailscale scraper proxy | **not installed** |
| `node-C` | `offsite-2` | storage + Tailscale scraper proxy | **not installed** |
| `node-D` | (gateway) | proxy only → Garage gateway (no data) | **ALREADY IN PRODUCTION** |

So: provision A/B/C from bare metal; node-D is live and gets a *careful additive*
reconfiguration in Phase 3 (do not wipe it). Work top to bottom — phases gate on
each other (no cluster before A exists; no data-plane backups before the gateway
routes; no monitoring before there are jobs to watch).

## Addressing

Pick the real values during Phase 0 and freeze them in `garage-fleet/addressing.md`.
Garage RPC/S3/admin ride the **tailnet only**.

| What | Value (fill in Phase 0) |
|---|---|
| Garage version | `v2.3.0` (pin; Renovate-tracked) |
| `replication_factor` | `3` (identical on every node) |
| `consistency_mode` | `consistent` (default) |
| Zones | `onsite` (A), `offsite-1` (B), `offsite-2` (C) |
| Tailnet domain | `<tailnet>.ts.net` (MagicDNS) |
| node-A overlay IP | `100.x.x.A` |
| node-B overlay IP | `100.x.x.B` |
| node-C overlay IP | `100.x.x.C` |
| node-D overlay IP + current prod role | capture the **actual** tailnet IP and existing production role in Phase 0 — node-D is **not** `tailscale-proxy-00`'s target (that is `rsp-asp` at `100.100.98.5`). Do **not** use a `100.100.98.D`-style placeholder or assume it shares the residential-proxy device. |
| RPC / S3 / admin ports | `3901` / `3900` / `3903` (bound to `tailscale0` only) |
| S3 region | `garage` |
| S3 endpoint (in-cluster) | `http://node-D.<tailnet>.ts.net:3900` via Tailscale egress proxy |

> ⚠️ Bind `rpc_bind_addr` / `[s3_api] api_bind_addr` / `[admin] api_bind_addr` to
> each node's **`tailscale0` IP**, never `0.0.0.0`. A loose firewall + `0.0.0.0`
> bind exposes the S3 API beyond the tailnet and defeats the network isolation
> the whole moat assumes.

## Tooling preamble (fleet workstation)

```bash
# garage-fleet repo root, on your workstation
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # workstation age key
# nix with flakes enabled; deploy-rs + nixos-anywhere via `nix run`
nix flake show          # sanity: the fleet flake evaluates
```

For the k8s side, all commands assume **this** repo root and:

```bash
export TALOSCONFIG=bootstraping/talosconfig
export KUBECONFIG=bootstraping/kubeconfig
export SOPS_AGE_KEY_FILE=clusters/staging/age.agekey
```

---

## Phase 0 — decisions locked, secrets custody, repo scaffolding

**Objective.** Freeze every irreversible decision, stand up the `garage-fleet`
repo skeleton, establish SOPS recipients for the fleet, set up the Tailscale ACL
tags, and put break-glass secrets into offline custody — **before** any disk is
touched.

**Prerequisites.**
- 3 bare-metal machines (A/B/C) reachable by SSH on a rescue/live image, ≥1 GiB
  RAM each (nixos-anywhere kexec minimum), an SSD for metadata + larger disk(s)
  for data.
- node-D already on the tailnet and reachable.
- Tailscale admin access (to edit ACLs and mint auth keys).
- A password manager (e.g. Vaultwarden) and a physical safe for break-glass.

**Tasks.**
- [ ] **Lock decisions** (record in `garage-fleet/decisions.md`, mirroring 09):
      standalone NixOS+ZFS (not joined to Talos, not a 2nd k8s cluster);
      `replication_factor=3` across 3 zones; node-D gateway-only; native ZFS
      encryption (`aes-256-gcm`) so `zfs send -w` ships ciphertext; sops-nix
      (NOT Vault/OpenBao); `deploy-rs` for the remote fleet (**magic rollback** —
      a bad tailscaled change won't strand a node you can't physically reach).
- [ ] **Scaffold `garage-fleet`** (new git repo):
      ```
      garage-fleet/
        flake.nix                      # inputs: nixpkgs, disko, nixos-anywhere,
                                       #         sops-nix, deploy-rs
        .sops.yaml                     # recipients per node (see below)
        addressing.md  decisions.md
        hosts/
          common/                      # shared NixOS modules
            garage.nix  zfs.nix  tailscale.nix  sanoid.nix  hardening.nix
          node-a/{configuration.nix,disko.nix,hardware-configuration.nix}
          node-b/{configuration.nix,disko.nix,hardware-configuration.nix}
          node-c/{configuration.nix,disko.nix,hardware-configuration.nix}
          node-d/{configuration.nix}   # additive overlay only — see Phase 3
        secrets/
          garage-rpc.enc.yaml          # ONE shared rpc_secret, all nodes
          garage-admin.enc.yaml        # admin_token  (separate sops secret)
          garage-metrics.enc.yaml      # metrics_token (separate sops secret)
          tailscale-authkey.enc.yaml   # reusable, non-ephemeral, tagged
        deploy.nix / colmena.nix       # deploy-rs node map (targetHost=MagicDNS)
      ```
- [ ] **SOPS recipients for the fleet.** Decide the node age identity model.
      Recommended: derive each node's age key from its **Ed25519 SSH host key**
      (`ssh-to-age`), seeded at install (Phase 1). For now, add a placeholder
      `.sops.yaml` keyed by `hosts/node-*` path → that node's recipient + the
      workstation recipient. Encrypt fleet secrets to **all four** node
      recipients + workstation (so any node can decrypt the shared `rpc_secret`).
      > ⚠️ This is the fleet's `.sops.yaml`, **separate** from this repo's
      > `.sops.yaml` (staging `age137z0k…`, production `age1heestk…`). Different
      > trust domain — do not reuse the cluster's age keys for the backup tier.
- [ ] **Generate the shared Garage secrets** (encrypt into `garage-fleet/secrets/`):
      ```bash
      openssl rand -hex 32   # -> rpc_secret   (ONE value, shared cluster-wide)
      openssl rand -hex 32   # -> admin_token
      openssl rand -hex 32   # -> metrics_token
      ```
- [ ] **Tailscale ACL tags — deny-by-default.** Add to the tailnet policy:
      - `tag:garage` — the 4 backup nodes. Allow `tag:garage → tag:garage` on
        `3900,3901,3903` (the fleet talks to itself).
      - Allow the k8s proxy tag (`tag:k8s`, the tailscale-operator's tag) →
        `tag:garage` on **`tcp:3900` (S3) ONLY**. **Never** `3901` (RPC peering —
        a compromised cluster could join the gossip cluster) and **never** `3903`
        (the admin API at `3903` is the layout/key/bucket control plane, *not*
        metrics-only). Metrics are scraped from a **tailnet-side** Prometheus or
        per-node egress proxies (Phase 6), not by granting `tag:k8s` reach to
        `3903`.
      - keep the existing scraper-egress grants for B/C unchanged.
      > ⚠️ The prod cluster is a **semi-trusted tailnet peer**, not a third party:
      > the tailscale-operator authenticates with OAuth creds scoped **Devices
      > Core = write AND Auth Keys = write** and tags spawned devices `tag:k8s`
      > (see `infrastructure/controllers/staging/tailscale-operator/README.md`).
      > A full prod compromise yields the Garage S3 write key, those OAuth creds
      > (which can mint **new** `tag:k8s` devices), and an L3 path to Garage. So
      > `tag:k8s` must be **deny-by-default** for Garage and reach only `tcp:3900`;
      > the real immutability is ZFS-side, unreachable by any tailnet identity.
      Mint a **reusable, non-ephemeral, tagged, long/no-expiry** auth key →
      `tailscale-authkey.enc.yaml`.
      > ⚠️ This reusable `tag:garage` auth key is a **cluster-join credential** —
      > anyone who exfiltrates it can join a rogue device as `tag:garage`. On
      > suspected leak, **revoke it in the Tailscale admin console** (existing
      > devices keep their node keys, so revocation does not strand them) and
      > re-mint. Prefer per-node `ephemeral=false` keys over one shared reusable
      > key where practical.
- [ ] **Break-glass custody (the one deliberately-manual control).** Put an
      **offline, out-of-band** copy of *(a)* the fleet age private key(s),
      *(b)* the restic repo password, *(c)* the Velero/Kopia repo password,
      *(d)* the `talos-backup` age private key, and *(e)* the **ZFS dataset
      encryption key/passphrase** into **two physical locations** (paper/steel +
      password manager). These are catastrophic-loss items: lose them and the
      ciphertext backups are unrecoverable. The ZFS key especially: it is
      decryptable by **only the owning node's age key**, so if the node fleet is
      lost you cannot `zfs load-key`/mount the raw-send offsite vault without an
      offline copy — a restore-time circular dependency (09 §8). Confirm the
      offsite vault's received raw datasets are loadable from the break-glass copy,
      not only from a surviving node. Document custody in
      `garage-fleet/decisions.md` (location pointers, **never** the values).

**Verification gate.**
- [ ] `nix flake check` (in `garage-fleet`) passes; `sops -d secrets/garage-rpc.enc.yaml`
      decrypts on the workstation.
- [ ] Tailscale ACL saved; `tag:garage` exists; auth key minted (not yet used).
- [ ] Break-glass items physically present in 2 locations (sign-off in
      `decisions.md`).

**Rollback.** Nothing provisioned yet — delete the `garage-fleet` repo, revoke
the auth key, remove the ACL tag. Zero blast radius on prod.

---

## Phase 1 — provision node-A (onsite) + single-node Garage

**Objective.** Install NixOS+ZFS on node-A via disko + nixos-anywhere, bring up a
**single-node** Garage (`replication_factor=3` already, but one node for now), and
prove S3 PUT/GET + metrics work over the tailnet.

**Prerequisites.** Phase 0 gate green. node-A booted into a rescue/live image with
SSH-as-root reachable from the workstation.

**Tasks.**
- [ ] **Write `hosts/node-a/disko.nix`** — one ZFS pool, encrypted boundary at
      `bpool/garage`, separate meta/data datasets:
      ```nix
      # [fleet] hosts/node-a/disko.nix  — SKELETON, not full impl
      {
        disko.devices.zpool.bpool = {
          type = "zpool";
          mode = "";                         # single disk; "mirror"/"raidz1" if multi
          rootFsOptions = { compression = "zstd"; "com.sun:auto-snapshot" = "false"; };
          datasets = {
            "garage" = {                      # encryption boundary
              type = "zfs_fs";
              options = {
                encryption = "aes-256-gcm";
                keyformat  = "passphrase";
                keylocation = "file:///tmp/zfs.key";   # seeded by nixos-anywhere
                # ⚠️ boot-trust: file:// + sops-nix-persisted passphrase means the
                # node AUTO-UNLOCKS at boot (the age identity that decrypts the
                # passphrase lives on the same disk, derived from the on-disk SSH
                # host key). So ZFS-at-rest here protects only against MEDIA-ONLY
                # theft (pulled platter / RMA), NOT whole-box theft. For unattended
                # offsite nodes that must stay locked when stolen, use
                # keylocation=prompt or initrd-SSH / Tailscale remote unlock and
                # accept the unattended-reboot toil. See 09 §7 boot-trust note.
              };
            };
            "garage/meta" = { type = "zfs_fs"; mountpoint = "/srv/garage/meta";
                              options.recordsize = "16K"; };
            "garage/data" = { type = "zfs_fs"; mountpoint = "/srv/garage/data";
                              options.recordsize = "1M"; };
          };
        };
      }
      ```
- [ ] **Write `hosts/common/garage.nix`** — native NixOS `services.garage`:
      ```nix
      # [fleet] hosts/common/garage.nix  — SKELETON
      { config, lib, pkgs, ... }:
      let
        # NOTE: there is NO `config.tailscaleIp` option in NixOS and
        # `services.tailscale` does NOT export the assigned 100.x address at eval
        # time. The overlay IP must be SUPPLIED — define a custom option and set
        # it per host, OR bind by interface some other way. Here we declare it:
        tsIp = config.fleet.tailscaleIp;   # set per host in node-*/configuration.nix
      in {
        options.fleet.tailscaleIp = lib.mkOption {
          type = lib.types.str;
          description = "This node's tailscale0 overlay IP (looked up / set per host).";
        };
        config = {
          services.garage = {
            enable = true;
            package = pkgs.garage_2;            # pin v2.3.0 via flake input
            settings = {
              metadata_dir = "/srv/garage/meta";
              data_dir     = "/srv/garage/data";
              db_engine    = "lmdb";
              replication_factor = 3;            # IDENTICAL on every node
              consistency_mode   = "consistent";
              metadata_auto_snapshot_interval = "6h";   # LMDB corruption guard
              rpc_bind_addr   = "[${tsIp}]:3901";
              rpc_public_addr = "[${tsIp}]:3901";   # OVERLAY IP
              rpc_secret_file = config.sops.secrets."garage-rpc".path;
              s3_api = { api_bind_addr = "[${tsIp}]:3900";
                         s3_region = "garage"; };
              # admin/metrics tokens via *_file ONLY — inline values would render
              # into the world-readable Nix store. (_file supported since v0.8.2.)
              admin  = { api_bind_addr = "[${tsIp}]:3903";
                         admin_token_file   = config.sops.secrets."garage-admin".path;
                         metrics_token_file = config.sops.secrets."garage-metrics".path; };
            };
          };
          sops.secrets."garage-rpc".restartUnits     = [ "garage.service" ];
          sops.secrets."garage-admin".restartUnits   = [ "garage.service" ];
          sops.secrets."garage-metrics".restartUnits = [ "garage.service" ];
        };
      }
      ```
      > ⚠️ `config.tailscaleIp` is **not** a real NixOS option and
      > `services.tailscale` does not expose the assigned `100.x` address at
      > evaluation time. The overlay IP must be **injected** — a custom option set
      > per host (as above), a sops value, or hardcoded per node. Do not reference
      > a `config.tailscaleIp` that does not exist or evaluation fails with
      > `attribute 'tailscaleIp' missing`.
- [ ] **Write `hosts/common/tailscale.nix`** (`services.tailscale.enable`,
      `authKeyFile = config.sops.secrets."tailscale-authkey".path`,
      `useRoutingFeatures` as needed), `hosts/common/hardening.nix`
      (`networking.firewall.enable = true; trustedInterfaces = [ "tailscale0" ]`,
      `services.zfs.autoScrub.enable = true`, `services.zfs.trim.enable = true`),
      and `hosts/node-a/configuration.nix` importing common + disko + sops-nix.
- [ ] **Provision** from the workstation:
      ```bash
      # seed the ZFS key + ssh host key so sops-nix can decrypt from first boot
      nix run .#nixos-anywhere -- \
        --flake .#node-a \
        --disk-encryption-keys /tmp/zfs.key ./local-zfs.key \
        --extra-files ./node-a-extra \        # /etc/ssh/ssh_host_ed25519_key
        --generate-hardware-config nixos-generate-config hosts/node-a/hardware-configuration.nix \
        --target-host root@<node-a-rescue-ip>
      ```
      > ⚠️ Add node-A's resulting age recipient (from its seeded SSH host key) to
      > `garage-fleet/.sops.yaml` and **re-encrypt the fleet secrets** before the
      > first `deploy-rs` push, or activation can't decrypt and switch fails.
- [ ] **Bootstrap the single-node layout** on node-A (over SSH/tailnet):
      ```bash
      garage status                                   # note node id
      garage layout assign <node-id> -z onsite -c <bytes>
      garage layout apply --version 1                 # exactly prev+1
      ```
- [ ] **Smoke-test S3.** Create a throwaway key+bucket, PUT/GET an object:
      ```bash
      garage key create smoke
      garage bucket create smoke-bkt
      garage bucket allow --read --write smoke-bkt --key smoke
      aws --endpoint http://<node-a-ts-ip>:3900 s3 cp /etc/hostname s3://smoke-bkt/
      ```

**Verification gate.**
- [ ] `garage status` shows node-A healthy; `garage layout show` shows version 1,
      one storage node in zone `onsite`.
- [ ] S3 round-trip succeeds; object hash matches.
- [ ] `curl -H "Authorization: Bearer <metrics_token>" http://<node-a-ts-ip>:3903/metrics`
      returns Prometheus metrics. `nmap`/`ss` confirms 3900/3901/3903 are **not**
      bound on the public NIC.
- [ ] `zfs list -t snapshot` shows the auto metadata snapshots accumulating.

**Rollback.** Single node, zero real data → `deploy-rs rollback` to a prior
generation, or re-run nixos-anywhere (disko **wipes** — fine, no backups yet).
Delete the smoke key/bucket.

---

## Phase 2 — provision node-B + node-C (offsite), form the gossip cluster

**Objective.** Install B and C identically, join all three into one Garage gossip
cluster **over Tailscale**, apply a 3-zone layout with `replication_factor=3`
(full mirror), and prove **site-loss tolerance**. Preserve B/C's existing
Tailscale scraper-egress proxy role.

**Prerequisites.** Phase 1 gate green. B and C on rescue images, reachable.

**Tasks.**
- [ ] **Author `hosts/node-b/*` and `hosts/node-c/*`** (disko + configuration),
      importing the same `hosts/common/*` modules. They differ only in
      hardware-configuration, disk topology, and zone.
- [ ] **Add the scraper-proxy role** to B/C via `hosts/common/tailscale.nix` (or a
      `scraper-proxy.nix`): advertise the subnet route / exit-node and approve in
      ACL. This **replaces** any role currently carried elsewhere — confirm the
      existing scraper egress keeps working (it consumes
      `tailscale-proxy-00.tailscale.svc.cluster.local` in-cluster, unchanged).
- [ ] **Provision** B then C with nixos-anywhere (same command shape as A;
      per-node `--extra-files`, seed SSH host key, add recipients to `.sops.yaml`,
      re-encrypt, deploy).
- [ ] **Set `bootstrap_peers`** in `garage.nix` to `pubkey@<overlay_ip>:3901` for
      all peers (or `garage node connect <id>@<ts-ip>:3901` once), so the three
      nodes find each other over the tailnet.
- [ ] **Stage + apply the 3-zone layout** (from any node):
      ```bash
      garage layout assign <id-A> -z onsite     -c <bytes>
      garage layout assign <id-B> -z offsite-1  -c <bytes>
      garage layout assign <id-C> -z offsite-2  -c <bytes>
      garage layout show                          # review STAGED
      garage layout apply --version 2             # exactly prev+1, ONCE
      ```
      > ⚠️ Never call `apply`/`revert` twice with the same `--version` — split-brain
      > risk. After apply settles (a few hours), run `garage repair -a --yes tables`.

**Verification gate.**
- [ ] `garage status` lists all 3 nodes healthy, 3 distinct zones.
- [ ] `garage layout show` = version 2, factor 3, one copy per zone.
- [ ] **Full-mirror proof:** PUT an object via node-A's S3; `garage block list-errors`
      clean; read the same object via node-B's and node-C's S3 endpoint.
- [ ] **Site-loss drill:** stop `garage.service` on node-C; with
      `consistency_mode=consistent` + factor 3, read/write quorum 2 is still met by
      A+B → S3 PUT/GET still succeed. Restart C; `garage repair -a --yes blocks`;
      confirm C re-replicates (`garage stats`).
- [ ] Scraper egress still flows through B/C (in-cluster scrape job succeeds).

**Rollback.** A bad layout is recoverable: `garage layout revert --version <N>`
before apply, or assign+apply a corrected version after. A bad NixOS push on a
remote node auto-reverts via deploy-rs **magic rollback**. No prod data at risk
(data plane not wired until Phase 4).

---

## Phase 3 — reconfigure node-D into a Garage gateway (no data)

**Objective.** Turn the **already-in-production** node-D into a Garage **gateway**
(capacity 0, stores no partitions) so the prod cluster has a single, nearby S3
entry point. **Additive, careful** — do not wipe or disrupt node-D's existing
production role.

**Prerequisites.** Phase 2 gate green. node-D under NixOS management *or* bring it
under `garage-fleet` management additively (Phase 0 created `hosts/node-d/` as an
overlay only).

**Tasks.**
- [ ] **Add `services.garage` to `hosts/node-d/configuration.nix`** importing the
      same `hosts/common/garage.nix`, but **no data**: it joins via the shared
      `rpc_secret` and the same `bootstrap_peers`. metadata/data dirs can be tiny
      (a gateway holds no partitions, but the binary still needs the dirs).
- [ ] **Deploy with deploy-rs** (magic rollback armed — node-D is remote and
      production-critical, so this is exactly the scenario magic rollback protects).
- [ ] **Assign as gateway** and apply (no zone — a gateway holds no partitions,
      so a zone is meaningless and inventing a fourth `gateway` zone misleads a
      reader into thinking node-D contributes a replication zone):
      ```bash
      garage layout assign <id-D> --gateway   # capacity 0, no data, NO zone
      garage layout show
      garage layout apply --version 3          # prev+1, ONCE
      ```

**Verification gate.**
- [ ] `garage layout show` shows node-D as **gateway** (no capacity, no partitions).
- [ ] S3 PUT via **node-D's** endpoint succeeds and the object lands on A/B/C
      (verify with `garage bucket info` object count on a storage node, not D).
- [ ] node-D's **existing production role is unaffected** (its prior service still
      healthy — explicit check before declaring done).

**Rollback.** `garage layout assign <id-D> --remove` + `apply --version 4`, then
`deploy-rs rollback` node-D to the pre-gateway generation. node-D's production
role was never modified, only added to.

---

## Phase 4 — wire data-plane backups (Flux-managed, this repo)

**Objective.** Make prod actually back up **into Garage**: etcd snapshots,
CNPG WAL+base backups, and selected Longhorn PVCs — each **client-side encrypted**
before upload. All Flux-managed in **this** repo. Reuse 03's CNPG mechanics; only
the *new* Garage destination is documented here.

**Prerequisites.** Phases 1–3 green (Garage reachable at the gateway). A Tailscale
**egress proxy** to reach Garage in-cluster: add a **NEW** ExternalName block to
`infrastructure/controllers/staging/tailscale-operator/egress-proxies.yaml`
(e.g. `tailscale-proxy-garage`) whose `tailscale.com/tailnet-ip` annotation is
**node-D's actual tailnet IP** (captured in Phase 0). In-cluster S3 endpoint
becomes `http://tailscale-proxy-garage.tailscale.svc.cluster.local:3900`.
> ⚠️ Do **not** repoint the existing `tailscale-proxy-00` — it targets
> `100.100.98.5` (`rsp-asp`, the residential scraper-egress proxy) and repointing
> it would break asp scraper egress. This is a *new, additional* block, copied in
> shape from the existing one but with node-D's IP and a distinct name.

### 4a — etcd snapshots → restic → Garage

> ⚠️ **Cross-substrate ordering gate.** This Talos machine-config change must be
> applied and confirmed on **all three CP nodes** *before* the CronJob's first
> scheduled run. Flux reconciles the CronJob from git; if it runs before
> `talosctl apply-config` has rolled `kubernetesTalosAPIAccess` to every CP node,
> every run fails to reach the Talos API. Either apply the talconfig change first
> and confirm it, or create the CronJob **suspended** (`spec.suspend: true`) and
> un-suspend only after the rollout is verified. Confirm
> `allowedKubernetesNamespaces` matches the CronJob namespace (`backup`) exactly.

- [ ] **Enable the Talos machine-API access** by **merging
      `kubernetesTalosAPIAccess` into the existing `machine.features` map** in the
      talhelper `patches:` block of `bootstraping/talconfig.yaml` — the *same*
      patch that already sets `diskQuotaSupport` / `kubePrism` / `hostDNS` (around
      line 113). Do **not** add a second `machine:` stanza or a new patch with its
      own `machine.features` — that duplicates the key and breaks the
      strategic-merge render. Add it as a sibling of the existing feature keys:
      ```yaml
      # bootstraping/talconfig.yaml — INSIDE the existing patches: -> machine: -> features:
      # (alongside diskQuotaSupport / kubePrism / hostDNS — do NOT create a new block)
            features:
              diskQuotaSupport: true
              kubePrism:
                enabled: true
                port: 7445
              hostDNS:
                enabled: true
                forwardKubeDNSToHost: true
              kubernetesTalosAPIAccess:                # <-- ADD THIS KEY ONLY
                enabled: true
                allowedRoles: [ os:etcd:backup ]       # least-privilege ONLY
                allowedKubernetesNamespaces: [ backup ]
      ```
      Then render and apply (per CLAUDE.md):
      ```bash
      cd bootstraping && SOPS_AGE_KEY_FILE=../clusters/staging/age.agekey talhelper genconfig
      talosctl validate --config clusterconfig/Homelab_staging-staging-controlplane-1.yaml --mode metal
      talosctl apply-config ...   # roll to ALL THREE CP nodes, then confirm
      ```
      > ⚠️ Without this the in-cluster snapshot pod cannot reach the Talos API at
      > all. Use `os:etcd:backup`, never `os:admin` (a pod-mounted admin token is a
      > cluster-takeover credential).
- [ ] **Mint a scoped talosconfig** and store as a SOPS Secret:
      ```bash
      talosctl config new --roles=os:etcd:backup etcd-backuper
      ```
- [ ] **Create the CronJob** (use Sidero `talos-backup`: snapshot → zstd →
      **age-encrypt client-side** → S3, `USE_PATH_STYLE=true`):
      ```yaml
      # [k8s] infrastructure/services/staging/etcd-backup/cronjob.yaml — SKELETON
      apiVersion: batch/v1
      kind: CronJob
      metadata: { name: etcd-backup, namespace: backup }
      spec:
        schedule: "0 */6 * * *"
        jobTemplate:
          spec:
            template:
              spec:
                restartPolicy: OnFailure
                containers:
                  - name: talos-backup
                    image: ghcr.io/siderolabs/talos-backup:<pin>
                    env:
                      # Names below are the ones talos-backup actually reads
                      # (per upstream cronjob.sample.yaml). Do NOT invent names.
                      - { name: USE_PATH_STYLE, value: "true" }
                      - { name: CUSTOM_S3_ENDPOINT, value: "http://tailscale-proxy-garage.tailscale.svc.cluster.local:3900" }
                      - { name: BUCKET, value: "etcd-staging" }
                      - { name: CLUSTER_NAME, value: "homelab-staging" }
                      # CLIENT-SIDE encryption recipient — MUST be this exact name:
                      - { name: AGE_RECIPIENT_PUBLIC_KEY, valueFrom: { secretKeyRef: { name: etcd-backup-age, key: pub } } }
                      # S3 creds (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_REGION)
                      # from garage-backup-credentials Secret
                    volumeMounts:
                      - { name: talosconfig, mountPath: /var/run/secrets/talos.dev }
      ```
      > ⚠️ The encryption recipient var is **`AGE_RECIPIENT_PUBLIC_KEY`**, not
      > `AGE_X25519_PUBLIC_KEY`. With the wrong name talos-backup does **not** pick
      > up the age recipient and uploads **UNENCRYPTED** snapshots — silently
      > defeating the client-side-encryption guarantee the whole design rests on.
      > `BUCKET` and `CLUSTER_NAME` are required too; `CUSTOM_S3_ENDPOINT` +
      > `USE_PATH_STYLE` are the correct Garage/path-style vars.
- [ ] **File map** `[k8s] infrastructure/services/staging/etcd-backup/`:
      `cronjob.yaml`, `namespace.yaml` (ns `backup`),
      `talosconfig.enc.yaml` (scoped config, SOPS, **staging/ overlay only**),
      `garage-backup-credentials.enc.yaml` (S3 key/secret),
      `etcd-backup-age.enc.yaml` (age pubkey is non-secret but keep the pair
      together), `kustomization.yaml`. Add a Garage **bucket+key** (Phase 0 style)
      `garage bucket create etcd-staging` / `garage key create etcd-backuper`.

### 4b — CNPG WAL + base backups → Garage

- [ ] **Add a Garage `ObjectStore`** alongside the existing R2 one (03 owns the
      mechanics — do **not** re-explain Barman/WAL/PITR). A Garage target is just
      another `ObjectStore` with a different `destinationPath` / `endpointURL` /
      credentials Secret. Follow the **asp** wiring pattern
      (`apps/staging/databases/asp/kustomization.yaml`): `resources` += the new
      `objectstore-garage.yaml` + creds; `patches` attach it to the `Cluster`.
      ```yaml
      # [k8s] objectstore-garage.yaml — SKELETON (see 03 for full field set)
      apiVersion: barmancloud.cnpg.io/v1
      kind: ObjectStore
      metadata: { name: garage-store }
      spec:
        configuration:
          destinationPath: s3://cnpg-staging
          endpointURL: http://tailscale-proxy-garage.tailscale.svc.cluster.local:3900
          s3Credentials:
            accessKeyId:     { name: garage-backup-credentials, key: ACCESS_KEY_ID }
            secretAccessKey: { name: garage-backup-credentials, key: ACCESS_KEY_SECRET }
          wal:  { compression: gzip }       # gzip is COMPRESSION, not encryption
          data: { compression: gzip }
          # NOTE: `encryption: AES256` is intentionally OMITTED here, unlike the
          # live R2 stores (apps/staging/databases/asp/objectstore.yaml,
          # infrastructure/services/staging/keycloak/database/objectstore.yaml),
          # which set it on wal+data. AES256 is S3 SERVER-side encryption and
          # Garage may not honour the header; omit pending verification. This is a
          # deliberate divergence from the asp pattern this plan otherwise mirrors.
          # serverName MUST be empty here — set it on the Cluster plugin params (03).
      ```
      > ⚠️ The R2 `instanceSidecarConfiguration.env`
      > `AWS_REQUEST_CHECKSUM_CALCULATION/…VALIDATION=when_required` block exists
      > **only** to work around Cloudflare R2 rejecting boto3≥1.36 checksums
      > (plugin issue #411). Garage (MinIO-style) accepts those checksums — **omit
      > the env block** for the Garage ObjectStore. HTTP-only endpoint → omit
      > `endpointCA`. Path-style addressing is handled by barman-cloud.
      > **CNPG backups are NOT client-side encrypted** (gzip = compression; SSE
      > may be ignored) — they may land plaintext at rest on Garage, protected only
      > by tailnet transit + ZFS-at-rest (which auto-unlocks at boot). Unlike the
      > etcd/Velero paths, do not claim "ciphertext only" for Postgres (09 §6).
- [ ] **Resolve the WAL-archiver fork** (single-WAL-archiver constraint — CNPG's
      plugin marks exactly **one** `ObjectStore` as `isWALArchiver: true`; a
      cluster cannot have two simultaneous WAL archivers). Pick **one** and record
      it here:
      - **(a) Garage REPLACES R2 as the WAL archiver** — prod doc 03's R2 ObjectStore
        is demoted to base-only or removed; Garage then holds the full PITR chain
        (WAL + base), so the Phase 7 Garage-only restore drill can do true PITR; or
      - **(b) R2 stays the WAL archiver; Garage gets independent scheduled BASE
        backups only** — then base backups fan out to Garage, but the Garage-only
        restore drill is **base-only, not PITR** (adjust Phase 7 accordingly).
      Either way keep a *separate* `ObjectStore` + bucket; do not point two writers
      at the same prefix. **"Add Garage alongside R2" is not a free additive change
      for the same cluster** — base backups can fan out, continuous WAL cannot.

### 4c — Velero + Longhorn CSI → Garage (the single PVC mover)

- [ ] **Install Velero** as a Flux controller (HelmRelease shape per repo
      convention: `infrastructure/controllers/base/velero/{release.yaml,
      repository.yaml,namespace.yaml,kustomization.yaml}` + staging overlay +
      a Kustomization block in `clusters/staging/infrastructure.yaml`). Install
      with `--use-node-agent` (Kopia data mover is **mandatory** for CSI data
      movement) and the `velero-plugin-for-aws`.
- [ ] **BackupStorageLocation** for Garage:
      ```yaml
      # [k8s] velero BSL — SKELETON
      spec:
        provider: aws
        objectStorage: { bucket: velero-staging }
        config:
          region: garage
          s3Url: http://tailscale-proxy-garage.tailscale.svc.cluster.local:3900
          s3ForcePathStyle: "true"      # REQUIRED for Garage/MinIO
      ```
- [ ] **Label the Longhorn `VolumeSnapshotClass`** `velero.io/csi-volumesnapshot-class: "true"`
      and set parameter **`type: snap`** (in-cluster snapshot for the data mover;
      `type: bak` would push to Longhorn's own backupstore — wrong path).
- [ ] **`Schedule`** with `--snapshot-move-data`, scoped to selected namespaces
      (e.g. `includedNamespaces`/`labelSelector`).
      > ⚠️ **Do NOT** also enable Longhorn-native recurring backups on the same
      > PVCs — pick one mover per volume (double snapshot churn, retention races,
      > duplicated cost). Velero is **the** PVC mover here.

**Verification gate (per stream).**
- [ ] **etcd:** a CronJob run completes; the object exists in `etcd-staging`
      bucket; downloading it shows `age`-encrypted ciphertext (not a readable
      `.snapshot`). `garage bucket info etcd-staging` object count increments.
- [ ] **CNPG:** WAL files appear under `cnpg-staging`; a `Backup`/`ScheduledBackup`
      completes (`kubectl get backups -A`); WAL + base present (encrypted in
      transit via tailnet; gzip at rest).
- [ ] **Velero:** `velero backup get` shows `Completed`; the `DataUpload` CRs
      finished; objects land in `velero-staging`; the Kopia repo is encrypted.
- [ ] Each stream targets a **distinct bucket** with a **distinct write key**.

**Rollback.** Each stream is independent and additive — suspend the CronJob /
`ScheduledBackup` / Velero `Schedule`, or remove its kustomize block and let Flux
prune. For 4a, reverting `talconfig.yaml` + re-apply removes the Talos API access.
Prod workloads untouched.

---

## Phase 5 — ransomware defense layers (the moat)

**Objective.** Make stolen S3 credentials **non-destructive**: even a key that can
delete every object cannot touch history. Layer client-side encryption (already in
Phase 4) with ZFS read-only snapshots pruned by a *separate* identity, and ZFS
encryption + scrub.

**Prerequisites.** Phases 1–4 green (real backups now flowing).

**Tasks.**
- [ ] **sanoid RO snapshots** on every **storage** node (A/B/C — not the gateway),
      via `hosts/common/sanoid.nix`:
      ```nix
      # [fleet] hosts/common/sanoid.nix — SKELETON
      services.sanoid = {
        enable = true;
        templates.garage = { hourly = 48; daily = 30; monthly = 3;
                             autosnap = true; autoprune = true; };
        datasets."bpool/garage" = { useTemplate = [ "garage" ]; recursive = true; };
      };
      ```
- [ ] **Enforce the ZFS-layer separation of duties (the only real SoD).** The
      nixpkgs sanoid module runs as **`DynamicUser=sanoid`** and `zfs allow`s
      itself `snapshot,mount,destroy` at `ExecStartPre`. The moat holds **only**
      because the **garage** service user has *zero* `zfs allow` on `bpool/garage`.
      **Never** `zfs allow garage …destroy/rollback`. Audit after deploy:
      ```bash
      zfs allow bpool/garage      # garage user must appear NOWHERE
      ```
      Optionally `zfs hold` critical snapshots to block `destroy` even by root.
      > ⚠️ **Be honest: object-level SoD is NOT a control here.** `restic forget
      > --prune` and Kopia maintenance need a `write`/owner grant on the **same**
      > bucket *plus* the repo password — they cannot run "node-side" on a Garage
      > storage node (which holds only opaque encrypted S3 objects and no repo
      > password), and if pruning runs as an in-cluster CronJob it holds **both**
      > the write key and the repo password, collapsing SoD. So the write identity
      > *can* `restic forget`/Kopia-maintain its repos; their immutability comes
      > **solely from the ZFS snapshot tier above**, not from object-level SoD.
      > Treat restic/Kopia retention as best-effort, and do not claim a separate
      > "prune key" exists. (A truly separated object pruner would be a backup-tier
      > job holding the repo password + a distinct owner key the cluster never
      > sees — not built here.)
- [ ] **ZFS native encryption** already set at the `bpool/garage` boundary (Phase 1
      disko). Confirm snapshots inherit it; this is what lets a future offsite
      `zfs send -w` carry **ciphertext** to an untrusted vault.
- [ ] **Scrub + trim timers** (`services.zfs.autoScrub.enable`,
      `services.zfs.trim.enable`) — already in `hardening.nix`; confirm enabled.
- [ ] **Network isolation** — confirm Garage binds only `tailscale0`, ACLs scoped
      (Phase 0/1). This is layer 5 of the moat.
- [ ] **Document the limitation honestly:** Garage **v2.3.0 has NO Object Lock and
      NO S3 versioning** (issue #166 open; #1127 open). Do **not** rely on
      bucket-level immutability — the immutability lives **entirely** in the ZFS
      snapshot tier. (The seed's "enable Garage versioning" step is **dropped** as
      unimplemented; record this in 09/10 so readers don't over-trust the bucket.)

**Verification gate.**
- [ ] `zfs list -t snapshot bpool/garage` shows the hourly/daily ladder growing and
      pruning per policy.
- [ ] `zfs allow bpool/garage` shows **only** the `sanoid` user holding `destroy`;
      the `garage` user holds none.
- [ ] **Moat drill:** using a *write* S3 key, delete an object; confirm it's gone
      from the live bucket **but** present in the latest ZFS snapshot
      (`zfs clone bpool/garage/data@<snap> bpool/restore/data`, point a scratch
      Garage at the clone, read the object back). Then `zfs destroy bpool/restore/data`.
- [ ] `zpool status` clean; scrub timer scheduled.

**Rollback.** sanoid/encryption/scrub are additive node config — `deploy-rs
rollback` removes them. Snapshots already taken persist (harmless). No effect on
the data plane.

---

## Phase 6 — monitoring + alerting

**Objective.** Watch every backup job and the Garage cluster; alert on **failure**
and on **staleness** (dead-man's-switch: too long since the last success). Extend
the existing Telegram alerting from `documentations/05-alerting.md`.

**Prerequisites.** Phase 4 streams running; Phase 5 done.

**Tasks.**
- [ ] **Scrape Garage metrics (per node).** Each node serves `/metrics` on its
      admin port `3903`, behind `metrics_token`. Two valid paths — pick one:
      - **(i) Preferred — tailnet-side Prometheus:** a Prometheus that already sits
        on the tailnet scrapes all **four** nodes directly with `authorization:
        { type: Bearer, credentials: <metrics_token> }`. The prod cluster's ACL
        then never needs reach to `3903` (the admin/control port).
      - **(ii) In-cluster Prometheus:** route through Tailscale egress proxies —
        **one ExternalName proxy per node**. A single egress proxy maps to exactly
        one tailnet device IP, so scraping all four nodes (A/B/C storage + D
        gateway) needs **four** egress-proxy Services (copy the
        `egress-proxies.yaml` block four times, one per node overlay IP). One proxy
        would silently leave A/B/C unmonitored and break the per-node
        `GarageNodeDown` alert below.
      > ⚠️ Do **not** grant `tag:k8s` ACL reach to `3903` just to scrape — `3903`
      > is the admin/control plane, not metrics-only (Phase 0 ACL). Path (i) avoids
      > the issue entirely; path (ii) still hits `3903` so it requires the proxies
      > to be the *only* clients and the token to gate access.
- [ ] **PrometheusRule for backups** — new file
      `monitoring/configs/staging/garage-backup/prometheusrule.yaml`:
      ```yaml
      # [k8s] — SKELETON. MUST carry label release: kube-prometheus-stack
      metadata:
        labels: { release: kube-prometheus-stack }   # else ruleSelector ignores it
      spec:
        groups:
          - name: backups
            rules:
              - alert: EtcdBackupStale         # dead-man's-switch
                expr: time() - max(kube_job_status_completion_time{job_name=~"etcd-backup.*"}) > 86400
                for: 10m
              - alert: CNPGBackupFailed
                expr: cnpg_collector_last_failed_backup_timestamp > cnpg_collector_last_available_backup_timestamp
              - alert: VeleroBackupFailed
                expr: velero_backup_failure_total > 0
              - alert: GarageNodeDown
                expr: up{job="garage"} == 0
      ```
      > ⚠️ Label trap (05): the rule **must** carry `release: kube-prometheus-stack`
      > or Prometheus' `ruleSelector` ignores it; PodMonitors need it too. CNPG
      > already has `podMonitorEnabled`, so CNPG backup alerts build on existing
      > metrics. Flux metric alerts use the `exported_namespace` label, not
      > `namespace`.
- [ ] **Dead-man's-switch.** Either the `time() - last_success` rule above, or wire
      each job to **Healthchecks.io** (ping on success; HC pages on absence). Pick
      one and document it.
- [ ] **Route backup alerts through Alertmanager → Telegram, NOT the Flux
      `Alert`.** Wire the new PrometheusRule alerts to the existing Telegram
      receiver (token via `alertmanagerSpec.secrets` + `bot_token_file`, never
      inline).
      > ⚠️ Do **NOT** add `backup`/`velero`/`garage` namespaces to the Flux
      > `Alert` `eventSources` (`monitoring/configs/staging/flux-alerts/alert.yaml`)
      > for backup-failure alerting — the notification-controller `Alert` only
      > matches **Flux-managed kinds** (`HelmRelease`, `Kustomization`, …; the live
      > file lists only those). A CronJob (etcd-backup), a Velero `Backup` CR, or
      > the Garage process emit **no** notification-controller events, so those
      > namespaces in `eventSources` capture **nothing** — a silent gap that looks
      > wired but is not. **All** backup-failure/staleness alerting comes from the
      > PrometheusRule → Alertmanager → Telegram path above. You *may* add the new
      > Garage/Velero **HelmRelease** namespaces to `eventSources` to alert on
      > *operator-install* failures — but that covers deploy failures, not
      > backup-job failures; be explicit about which.

**Verification gate.**
- [ ] Garage targets show **UP** in Prometheus; `/metrics` scraped with the bearer
      token (un-tokened scrape from an unauthorized source is refused).
- [ ] Force a failure (suspend Garage, or fail one CronJob) → the corresponding
      alert fires and a **Telegram message arrives**.
- [ ] Let a job's last-success age exceed the threshold in a test → staleness alert
      fires (proves the dead-man's-switch, not just the failure path).

**Rollback.** Remove the PrometheusRule / ScrapeConfig (and any egress-proxy
blocks added for scraping) via kustomize; Flux prunes. Alerting-only — no data
impact.

---

## Phase 7 — automated restore drills (the "0" in 3-2-1-1-0)

**Objective.** Prove **recoverability**, not just that bytes uploaded. A scheduled
job restores each stream into a scratch target, runs an integrity check + a sanity
query, and alerts on failure. Plus one-command restore runbooks for real DR.

**Prerequisites.** Phases 4–6 green.

**Tasks.**
- [ ] **CNPG restore drill (CronJob) — scope must match the Phase 4b fork.**
      Bootstrap a throwaway `Cluster` from the Garage `ObjectStore` with
      `bootstrap.recovery` + an `externalClusters` entry (03 owns the mechanics),
      run a sanity query (`SELECT count(*) …`), then delete the scratch cluster.
      - If **Phase 4b (a)** (Garage is the WAL archiver): Garage holds WAL + base,
        so set a PITR `recoveryTarget.targetTime` and verify **true point-in-time
        recovery**.
      - If **Phase 4b (b)** (R2 stays the WAL archiver; Garage = base-only): a
        Garage-only restore is **base-only**, NOT PITR — drop `recoveryTarget` and
        verify the base restore restores to the base-backup point only.
      > ⚠️ CNPG recovery is **never in-place** — it always bootstraps a NEW cluster.
      > Always write `targetTime` with an explicit timezone (`…Z`) or you overshoot
      > by your local offset. Do not run a PITR drill against a Garage that is not
      > the WAL archiver — the WAL chain won't be there.
- [ ] **Velero restore drill.** `velero restore create` into a scratch namespace
      (remap with `--namespace-mappings`), confirm the PVC `DataDownload` completes
      and the data is present; tear down.
- [ ] **etcd snapshot check.** Decrypt the latest `talos-backup` object with the age
      key, verify it's a valid etcd snapshot (`etcdutl snapshot status`), confirm
      hash/revision/key-count are sane. (Do **not** actually `bootstrap
      --recover-from` against prod in a drill.)
- [ ] **Repo integrity checks.** `restic check` (etcd repo) and Kopia repo
      verification (Velero) on a schedule.
- [ ] **Write one-command DR runbooks** (`documentations/01` appendix or a sibling):
      - **etcd:** `talosctl reset --graceful=false --reboot
        --system-labels-to-wipe=EPHEMERAL` on ONE recovery CP node, then
        `talosctl -n <IP> bootstrap --recover-from=./db.snapshot` (snapshots from
        the `etcd snapshot` API carry a hash — **do not** pass
        `--recover-skip-hash-check`). Other CPs auto-rejoin. **Never** regenerate
        `talsecret` (new PKI = dead cluster).
      - **CNPG PITR:** apply the recovery `Cluster` manifest (mirror
        `apps/production/databases/asp/cluster-recovery-patch.yaml`).
      - **Velero:** `velero restore create --from-backup <name>`.
      - **Garage node/site loss:** re-add capacity, `garage repair -a --yes blocks`,
        let it re-replicate. **ZFS rollback** for ransomware: `zfs clone` the good
        snapshot, verify, then `zfs rollback -r` (destructive of newer snaps —
        clone-and-verify first).

**Verification gate.**
- [ ] Each restore-drill CronJob completes green on schedule; a deliberately
      corrupted/absent backup makes the drill **fail and alert** (proves the gate
      actually gates).
- [ ] The CNPG drill's sanity query returns expected row counts.
- [ ] The DR runbooks are executed once **manually end-to-end** against scratch
      targets and timed (record RTO/RPO in `decisions.md`).

**Rollback.** Drills run against scratch targets only — suspend the CronJobs to
stop. No production impact by construction.

---

## Phase 8 — cutover, handoff, version discipline

**Objective.** Declare the backup tier production, hand off the (minimal) ops
surface, and lock version pinning so Renovate can't silently break it.

**Prerequisites.** Phases 0–7 green.

**Tasks.**
- [ ] **Ops checklist** (in 09's Operations section): how to add a bucket+key
      (idempotently — no racing `CreateBucket` from two sites), how to read
      `garage status`/`layout`, how to run `garage repair`, how to deploy a node
      config change (`deploy-rs` with magic rollback), how to rotate the
      `rpc_secret` (rotate in sops → `restartUnits` restarts garage cluster-wide).
- [ ] **What stays manual (by design):** break-glass key custody (Phase 0) and the
      **decision to trigger a real DR restore**. Everything else is declarative +
      scheduled.
- [ ] **Version pinning + Renovate.** Pin (quoted strings, repo convention) and let
      Renovate bump: Garage `v2.3.0` (flake input + `services.garage.package`),
      Velero chart, `velero-plugin-for-aws`, `talos-backup` image,
      `nixpkgs`/`disko`/`sops-nix`/`deploy-rs` flake inputs.
      > ⚠️ Trip-wires: (1) CNPG past **1.30.0** removes the in-tree barman path —
      > already on the **plugin**, so safe, but keep operator/plugin versions
      > compatible (CNPG-I handshake). (2) Garage `replication_factor` and
      > `rpc_secret` must stay identical across all nodes — a Renovate-driven
      > config drift on one node breaks cluster formation. (3) Major Garage bumps:
      > read release notes for layout/version-table changes before applying.

**Verification gate.**
- [ ] A full dry-run of the ops checklist by following it literally (add a test
      bucket, deploy a no-op node change, rotate a throwaway secret).
- [ ] Renovate opens PRs for the pinned components (config in place).
- [ ] Sign-off: all phase gates green; restore drills green for ≥1 cycle.

**Rollback.** This phase is documentation + pinning — no infra change to revert.

---

## Consolidated ordered checklist

- [ ] **P0** Decisions locked; `garage-fleet` scaffolded; fleet `.sops.yaml` +
      shared `rpc_secret`/admin/metrics tokens; Tailscale `tag:garage` +
      **deny-by-default** ACL (`tag:k8s → tag:garage` is `tcp:3900` only) + auth
      key; node-D's real tailnet IP + prod role captured; break-glass (incl. ZFS
      key) in 2 offline locations.
- [ ] **P1** node-A installed (disko+nixos-anywhere); single-node Garage; layout v1;
      S3 round-trip + tokened metrics verified; binds tailnet-only.
- [ ] **P2** node-B + node-C installed; gossip cluster over Tailscale; layout v2
      (3 zones, factor 3); full-mirror + site-loss drill pass; scraper proxy intact.
- [ ] **P3** node-D = gateway (layout v3, `--gateway`, no data); prod role of D
      unaffected; S3 via D routes to A/B/C.
- [ ] **P4** etcd→age→Garage CronJob (`AGE_RECIPIENT_PUBLIC_KEY`/`BUCKET`/
      `CLUSTER_NAME`); CNPG Garage `ObjectStore` (WAL-archiver fork resolved,
      `encryption: AES256` omitted); Velero+CSI (`type: snap`, `--use-node-agent`,
      `s3ForcePathStyle`); etcd/Velero land client-side-encrypted (CNPG does not),
      distinct bucket/key. Talos `kubernetesTalosAPIAccess`/`os:etcd:backup` merged
      into the existing `machine.features` patch + rolled to all 3 CP nodes BEFORE
      first run; NEW egress proxy to node-D (not a repoint of `tailscale-proxy-00`).
- [ ] **P5** sanoid RO snapshots (A/B/C); moat invariant audited
      (`zfs allow bpool/garage` — garage user absent); ZFS encryption + scrub;
      no-Object-Lock/no-versioning limitation documented; moat drill passes.
- [ ] **P6** Garage metrics scraped (bearer; tailnet-side Prometheus OR one egress
      proxy per node); backup failure + **staleness** alerts via PrometheusRule →
      Alertmanager → Telegram (**not** the Flux `Alert` eventSources, which can't
      see CronJob/Velero/Garage events); failure + staleness both proven to fire.
- [ ] **P7** scheduled restore drills (CNPG PITR, Velero, etcd check, restic/Kopia
      check) green; deliberately-bad backup fails the drill; DR runbooks executed
      once manually; RTO/RPO recorded.
- [ ] **P8** ops checklist; manual-by-design surface documented; Renovate pinning +
      trip-wires; sign-off.

## Risk register

| Risk | Mitigation |
|---|---|
| **Garage has no Object Lock / no versioning (v2.3.0)** — a stolen write key wipes a bucket | Immutability lives **outside** Garage: ZFS RO snapshots pruned by a separate `sanoid` identity; client-side encryption (restic/Kopia paths) so theft leaks only ciphertext (P5). Versioning is **not** a moat layer. |
| **Prod cluster is a semi-trusted tailnet peer** (operator OAuth = Devices/Auth-Keys write; compromise mints `tag:k8s` devices + leaks S3 write key) | Deny-by-default ACL: `tag:k8s → tag:garage` is **`tcp:3900` only** (never 3901/3903); immutability is ZFS-side, unreachable by any tailnet identity (P0). |
| **Gateway node-D compromise** leaks the shared `rpc_secret` (cluster-wide RPC trust) and sits on the data path | `rpc_secret` grants only RPC peering over ciphertext; isolate node-D's prod workload from the Garage service so it can't read `/run/secrets/garage-rpc` (P3). |
| **ZFS at-rest auto-unlocks at boot** → not a whole-box node-theft defense | Accepted; real theft mitigation is client-side payload encryption (restic/Kopia). For unattended offsite nodes consider `keylocation=prompt` / initrd-SSH unlock (P1 disko note). |
| **Object-level retention is not separated** (write key can `restic forget`/Kopia-maintain) | Only the ZFS snapshot layer is a real SoD/immutability control; restic/Kopia retention is best-effort (P5). |
| **CNPG backups land plaintext at rest on Garage** (gzip = compression; SSE may be ignored) | Scoped exception: protected only by tailnet transit + ZFS-at-rest; add a client-side-encryption wrapper if Postgres-at-rest ciphertext is required (P4b). |
| **CNPG single-WAL-archiver constraint** — cannot have two live WAL archivers | Resolve the R2-vs-Garage fork explicitly (P4b); the Phase 7 PITR drill is valid only if Garage is the WAL archiver, else base-only. |
| **Talos API access wired before machine-config rollout** → CronJob fails every run | Cross-substrate gate: apply+confirm `kubernetesTalosAPIAccess` on all 3 CP nodes (or keep the CronJob `suspend: true`) before its first run; `allowedKubernetesNamespaces` must equal `backup` (P4a). |
| **Garage user gains `zfs destroy`** (e.g. to self-prune) punches through the moat | Hard invariant: never `zfs allow garage …destroy/rollback`; audit `zfs allow bpool/garage` in P5 gate; optional `zfs hold`. |
| **LMDB metadata corruption** after unclean shutdown is unrecoverable | `replication_factor=3` (never a single metadata copy) + `metadata_auto_snapshot_interval=6h`; size metadata dataset for ~4× snapshot overhead (P1). |
| **Layout `apply --version` misuse** → split-brain | Always `prev+1`, exactly once; review staged with `garage layout show`; `revert` before apply if wrong (P2/P3). |
| **Garage binds `0.0.0.0`** → S3 exposed beyond tailnet | Bind every listener to the `tailscale0` IP; firewall `trustedInterfaces=[tailscale0]`; ACL `tag:garage`; verified in P1 gate. |
| **Bad NixOS push strands a remote node** (broke tailscaled/firewall) | `deploy-rs` **magic rollback** auto-reverts; first post-install push done carefully (magic rollback needs a deploy-rs baseline). |
| **disko re-run wipes a live backup node** | disko create-mode **destroys disks** — only ever run nixos-anywhere on a node *before* it holds data; documented in P1/P2 tasks. |
| **sops-nix can't decrypt at activation** (SSH host key / recipient drift) | Seed `/etc/ssh/ssh_host_ed25519_key` via `--extra-files`, add the node recipient to `.sops.yaml` and **re-encrypt before first deploy**; never regenerate the SSH host key. |
| **CNPG R2 checksum env block copy-pasted to Garage** | Garage accepts boto3 checksums — **omit** the `AWS_*_CHECKSUM_*` env; it's an R2-only workaround (P4b). |
| **CNPG bumped past 1.30.0** removes in-tree barman | Already on the plugin; keep operator/plugin versions compatible; Renovate trip-wire noted (P8). |
| **Double-backup of a PVC** (Velero + Longhorn-native) | One mover per volume — Velero CSI is **the** PVC path; Longhorn-native recurring backups stay off for those volumes (P4c). |
| **Talos DR mistakes** (skip-hash on API snapshot, wipe wrong partition, regenerate talsecret) | Runbook: API snapshots keep their hash (no `--recover-skip-hash-check`); wipe only `EPHEMERAL` on **one** recovery node; **never** regenerate `talsecret` (P7). |
| **etcd snapshot pod can't reach Talos API** | Enable `kubernetesTalosAPIAccess` + `os:etcd:backup` + `allowedKubernetesNamespaces:[backup]`, render, `talosctl apply-config` (P4a). |
| **Backups silently stop** (cron broken, creds rotated) | Dead-man's-switch staleness alert (`time()-last_success`) + Healthchecks.io; restore drills catch unrecoverable-but-present backups (P6/P7). |
| **Loss of break-glass keys** = ciphertext unrecoverable | Offline out-of-band copies in 2 physical locations (paper/steel + password manager); the one deliberately-manual control (P0). |

## Secrets inventory

| Secret | Stored where | Who can decrypt |
|---|---|---|
| Garage `rpc_secret` (32-byte hex, **shared**) | `[fleet] garage-fleet/secrets/garage-rpc.enc.yaml` (sops) → `rpc_secret_file` on each node | fleet node age keys (A/B/C/D) + workstation |
| Garage `admin_token` / `metrics_token` | `[fleet] garage-fleet/secrets/garage-admin.enc.yaml` (sops) | fleet node age keys + workstation |
| Tailscale auth key (reusable, non-ephemeral, tagged) | `[fleet] garage-fleet/secrets/tailscale-authkey.enc.yaml` (sops) | fleet node age keys + workstation |
| ZFS encryption passphrase (`bpool/garage`) — **catastrophic-loss, also break-glass** | seeded at install via nixos-anywhere `--disk-encryption-keys`; persisted via sops-nix per node | that node's age key only → **un-recoverable if the node fleet is lost**; therefore ALSO keep an offline break-glass copy (P0) |
| Node age identity | derived from each node's Ed25519 SSH host key (`ssh-to-age`), seeded via `--extra-files` | the node itself |
| Garage S3 backup write keys (etcd / cnpg / velero — **distinct**) | `[k8s] …/staging/*/garage-backup-credentials.enc.yaml` (sops, **staging/ overlay only**, `stringData`) | this repo's **staging** age key `age137z0k…` |
| `talos-backup` age **public** key (etcd client-side encryption) | `[k8s] …/etcd-backup/etcd-backup-age.enc.yaml` | staging age key (pub is non-secret; kept with its pair) |
| `talos-backup` age **private** key (etcd restore) | **break-glass** — offline, 2 physical locations | humans only (offline) |
| restic repo password (etcd repo) | **break-glass** — offline, 2 physical locations + sops for the job | staging age key (job) + offline (recovery) |
| Velero/Kopia repo password | **break-glass** — offline, 2 physical locations + Velero Secret | Velero (job) + offline (recovery) |
| Scoped Talos `etcd-backuper` config (`os:etcd:backup`) | `[k8s] …/etcd-backup/talosconfig.enc.yaml` (sops, staging overlay only) | staging age key `age137z0k…` |
| Telegram bot token | existing `[k8s]` alertmanager secret (`bot_token_file`, 05) — unchanged | staging age key |

> ⚠️ Fleet secrets and cluster secrets are encrypted to **different** age
> recipients on purpose — the backup tier is a separate trust domain. Never
> encrypt a cluster secret to a fleet key or vice versa. **But** note the
> separation is not absolute: the prod cluster is a semi-trusted tailnet peer via
> the tailscale-operator (which can mint `tag:k8s` devices), so the ACL — not the
> key split alone — is what bounds cluster reach to Garage (`tcp:3900` only).

## See also

- `documentations/00-garage-backup-cluster.md` — design + rationale (the *why*).
- `documentations/03-backups.md` — CNPG→object-store mechanics (ObjectStore /
  ScheduledBackup / Barman plugin / PITR / Flux CRD-vs-CR ordering). This plan
  reuses those; it does not re-explain them.
- `documentations/05-alerting.md` — Telegram alerting this plan extends.
- `documentations/07-talos-ha-expansion.md` — Talos node-config + etcd recovery
  context for the etcd backup/restore path.
