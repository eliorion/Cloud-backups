# 06 — Garage S3 buckets: add a bucket, and access it with a key

How the fleet manages Garage S3 buckets + access keys **declaratively**, how to
**add a new bucket**, and how to **access a bucket** from a client with its key.

This is the standalone-fleet counterpart to the backup *jobs* that live in the prod
repo (etcd CronJob, CNPG ObjectStore, Velero) — those jobs are the *consumers* of the
buckets defined here. See `00-garage-backup-cluster.md` (design) and
`01-garage-backup-implementation-plan.md` (runbook) for the wider picture.

---

## Model — everything runs from the workstation

Garage bucket/key/permission state is **imperative runtime state** in the cluster
metadata store. The fleet makes it **reprovisionable** with one workstation-driven
tool, `scripts/fleet buckets`. **No node stores the S3 key material** and **no
on-node reconciler exists** — the workstation (the devcontainer) is the control
plane.

- **Spec** (single source of truth): `buckets.spec` at the repo root — one line per
  bucket, git-tracked, **not** a secret (bucket and *field names* only):

  ```
  bucket : key-name : id-field : secret-field
  ```

  `fleet buckets add` appends to it; you rarely edit it by hand. The `*-field` names
  are the flat keys used inside `secrets/s3-keys.enc.yaml`.
- **Key material**: `secrets/s3-keys.enc.yaml`, encrypted to the **workstation age
  key ONLY** (`.sops.yaml` rule) — never shipped to any node. `fleet buckets`
  pushes it to a live node over ssh, just-in-time, at apply time.
- **Commands**:

  | command | what it does |
  |---|---|
  | `fleet buckets add <bucket> [key-name]` | declare + mint + push a NEW bucket with its OWN key, then print its k8s Secret (all of the below in one shot) |
  | `fleet buckets creds <bucket> [--k8s]` | reprint that bucket's credentials + endpoint (stdout only) |
  | `fleet buckets keygen` | mint any missing key material (offline, local, idempotent) |
  | `fleet buckets apply` | create buckets + import keys + grant, on a live node (idempotent, additive) |
  | `fleet buckets status` | show live buckets / keys / permissions |
  | `fleet buckets browse <bucket>` | read-only object browser in your web browser (ssh tunnel + `rclone serve http`) |

### Current buckets (as shipped)

| bucket | key | grant | consumer |
|---|---|---|---|
| `homelab-staging-etcd-backup` | `etcd-key` | RW | prod etcd snapshot CronJob |
| `cnpg-staging-asp` | `cnpg-asp-key` | RW | CNPG cluster `staging-asp` (barman) |
| `cnpg-staging-fbref` | `cnpg-fbref-key` | RW | CNPG cluster `staging-fbref` (barman) |

**One key per bucket** — a leaked key exposes only its own cluster's backups.

### Permission model (read this before you expect "no delete")

Garage bucket keys have **only** three flags: `--read`, `--write`, `--owner`.
There is **no delete-less grant** — `--write` includes `PutObject` **and**
`DeleteObject`. You cannot make a key that writes but cannot delete. Garage 2.x has
no S3 lifecycle, no Object Lock, no WORM either.

Object immutability in this fleet is therefore the **ZFS snapshot moat**
(`modules/zfs-sanoid.nix`, read-only sanoid snapshots on the storage nodes): a
`DeleteObject` removes the live object but **not** the snapshot copy, so you restore
from the snapshot. Backup keys are `--read --write` and **never `--owner`** (owner =
delete the bucket, change config, manage keys). Pruning is manual on the node.

---

## Add a new bucket

One command. Example: a new CNPG cluster `staging-newapp` needs its own bucket and
its own dedicated key.

```bash
./scripts/fleet buckets add cnpg-staging-newapp
```

That does, in order:

1. **Validates** the name against S3/Garage rules (lowercase `a-z0-9.-`, 3–63
   chars, no `_`, no `..`) — before touching anything.
2. **Declares** it in `buckets.spec` with a **dedicated key**. The key name
   defaults to `<bucket>-key` (override as a 2nd argument) and the sops field names
   are derived from the bucket: `s3_cnpg_staging_newapp_id` /
   `…_secret`. Nothing to invent by hand.
3. **Mints** that key offline into `secrets/s3-keys.enc.yaml` — `GK…` id + 64-hex
   secret. Existing keys are kept, **never** regenerated.
4. **Applies** to a live storage node: creates the bucket, imports the key with its
   fixed id+secret, grants `--read --write`. If no node is reachable it says so and
   tells you to run `fleet buckets apply` later — the spec and key are already safe
   on disk.
5. **Prints** the ready-to-paste k8s Secret + `ObjectStore` endpoint (see below).

Re-running `add` for a bucket that already exists is **safe**: it re-declares
nothing, re-mints nothing, and just reconciles the cluster.

> ⚠️ **Both storage nodes must be up.** Creating/deleting a bucket or key is a
> **global-metadata write** and needs cluster quorum. With one node down at the
> current 2-node size, the write fails `Could not reach quorum`. Do bucket/key
> admin only when `fleet buckets status` (or `garage status`) shows every node
> HEALTHY. (This eases to quorum 2/3 once node-c joins and rf=3 — see
> `01-garage-backup-implementation-plan.md`.)

### Commit the spec + the encrypted secret

```bash
./scripts/fleet secrets      # choice 'v' verifies + stages buckets.spec & s3-keys.enc.yaml
git commit -m "fleet: add cnpg-staging-newapp bucket + key"
```

`secrets/s3-keys.enc.yaml` is committed **encrypted** (a flake copies only
git-tracked files; the values stay encrypted to the workstation key). `buckets.spec`
is plain text — it holds no key material.

### Hand the key to the consumer (prod repo)

`add` already printed it; to get it again:

```bash
./scripts/fleet buckets creds cnpg-staging-newapp --k8s   # CNPG-shaped Secret
./scripts/fleet buckets creds cnpg-staging-newapp         # plain id / secret / endpoint
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-staging-newapp-s3
  namespace: <ns>          # fill in
type: Opaque
stringData:
  ACCESS_KEY_ID: GK…
  ACCESS_SECRET_KEY: …
# ObjectStore: endpointURL http://<node>.<tailnet>.ts.net:3900   (any storage node serves S3)
#              destinationPath s3://cnpg-staging-newapp/   ·   region garage · path-style
```

Secret material goes to **stdout only**, never to a file — it lands in your
scrollback, so paste it and clear. The raw dump still works:
`nix run .#sops -- -d secrets/s3-keys.enc.yaml`.

### If a run stops half-way

`add` is just the four steps above, each idempotent and separately runnable — the
spec line survives, so pick up where it stopped:

```bash
./scripts/fleet buckets keygen    # mint only what is missing
./scripts/fleet buckets apply     # push every declared bucket + key (additive)
```

### Removing a bucket or key

`fleet buckets apply` is **additive** — it never prunes. Removing a line from
`buckets.spec` does **not** delete anything live (and leaves its now-orphaned
fields in `secrets/s3-keys.enc.yaml` — drop them with `sops edit`). Delete by hand
on a node (needs quorum):

```bash
ssh root@<node>.<tailnet>.ts.net 'garage -c /etc/garage.toml key delete --yes <GK…>'
ssh root@<node>.<tailnet>.ts.net 'garage -c /etc/garage.toml bucket delete --yes <bucket>'
```

---

## Access a bucket with its key

All Garage listeners bind the node's `tailscale0` overlay IP only. S3 API =
port **3900**. Reach it from a tailnet peer (prod k8s is `tag:k8s → tag:garage
tcp:3900`; your workstation over the tailnet).

- **Endpoint**: `http://<node-tailscale-ip>:3900` (e.g. node-a `http://100.64.0.10:3900`)
- **Region**: `garage`
- **Addressing**: **path-style** (Garage does not do virtual-host buckets)

Get a key's id/secret:

```bash
./scripts/fleet buckets creds <bucket>            # one bucket, with its endpoint
nix run .#sops -- -d secrets/s3-keys.enc.yaml     # or the whole file
```

### aws CLI

```bash
export AWS_ACCESS_KEY_ID=GK…             # e.g. cnpg-asp-key
export AWS_SECRET_ACCESS_KEY=…
aws --endpoint-url http://100.64.0.10:3900 --region garage \
    s3 ls s3://cnpg-staging-asp/
```

`~/.aws/config` needs `region = garage`; SDKs need path-style
(`s3ForcePathStyle=true` / `AWS_S3_FORCE_PATH_STYLE=1`).

### rclone

```ini
# ~/.config/rclone/rclone.conf
[garage]
type = s3
provider = Other
access_key_id = GK…
secret_access_key = …
endpoint = http://100.64.0.10:3900
region = garage
force_path_style = true
```

```bash
rclone ls   garage:cnpg-staging-asp
rclone tree garage:homelab-staging-etcd-backup
```

### Web browser (no server, no config) — `fleet buckets browse`

```bash
./scripts/fleet buckets browse cnpg-staging-asp        # default http://127.0.0.1:8080
```

Opens an ssh port-forward to the node's garage S3, then runs `rclone serve http`
on localhost with a throwaway config built from sops — **read-only** (an RW key
cannot mutate through this UI), torn down on Ctrl-C. Nothing is added to the
cluster. Per-bucket keys ⇒ browse is per-bucket.

---

## Reprovision (recreate a node / the cluster)

- **One node rebuilt** → bucket/key definitions are cluster metadata and **gossip
  back** from the surviving peer automatically. Nothing to run.
- **Whole cluster rebuilt** → `fleet buckets apply` once. `garage key import`
  restores the **identical** ids+secrets from sops, so no consumer re-wires.
- **Object data** durability is a separate axis = `replication_factor` (raise
  1→3 at node-c) + `garage repair`, or re-push from prod (the DR source of truth).

## Vault (what to keep off git)

The devcontainer workstation is disposable. `fleet status` has a **vault** section
listing the gitignored, non-regenerable files to keep in your password manager:
`private-keys/garage-fleet.txt` (decrypts everything) + each `private-keys/<node>-age.txt`,
plus the human-held ZFS passphrases and root passwords. `secrets/s3-keys.enc.yaml`
is committed (encrypted), so it is recovered from git + the fleet key — no separate
vault copy needed, though vault the plaintext values for prod wiring.
