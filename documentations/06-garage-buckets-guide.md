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

- **Spec** (single source of truth): the `buckets` section near the top of
  `scripts/fleet` — the `BUCKETS` list and the `S3_KEYS` lines.
- **Key material**: `secrets/s3-keys.enc.yaml`, encrypted to the **workstation age
  key ONLY** (`.sops.yaml` rule) — never shipped to any node. `fleet buckets`
  pushes it to a live node over ssh, just-in-time, at apply time.
- **Commands**:

  | command | what it does |
  |---|---|
  | `fleet buckets keygen` | mint any missing key material (offline, local, idempotent) |
  | `fleet buckets apply` | create buckets + import keys + grant, on a live node (idempotent, additive) |
  | `fleet buckets status` | show live buckets / keys / permissions |
  | `fleet buckets browse <bucket>` | read-only object browser in your web browser (ssh tunnel + `rclone serve http`) |

### Current buckets (as shipped)

| bucket | key | grant | consumer |
|---|---|---|---|
| `etcd-backup` | `etcd-key` | RW | prod etcd snapshot CronJob |
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

Example: add a bucket `velero` with its own key `velero-key`.

### 1. Edit the spec in `scripts/fleet`

In the `buckets` section, add the bucket and a key line:

```bash
BUCKETS=(etcd-backup cnpg-staging-asp cnpg-staging-fbref velero)   # <- add velero

S3_KEYS=(
  "etcd-key:s3_etcd_id:s3_etcd_secret:etcd-backup"
  "cnpg-asp-key:s3_cnpg_asp_id:s3_cnpg_asp_secret:cnpg-staging-asp"
  "cnpg-fbref-key:s3_cnpg_fbref_id:s3_cnpg_fbref_secret:cnpg-staging-fbref"
  "velero-key:s3_velero_id:s3_velero_secret:velero"                # <- add this
)
```

Format is `name : id-field : secret-field : bucket[,bucket,...]`. The `*_field`
names are the flat keys used inside `secrets/s3-keys.enc.yaml`.

### 2. Mint the key material (offline)

```bash
./scripts/fleet buckets keygen
```

Mints `GK…` id + 64-hex secret for any **missing** key (existing keys are kept,
never regenerated) into `secrets/s3-keys.enc.yaml`.

### 3. Apply to the cluster

```bash
./scripts/fleet buckets apply
```

Creates the bucket, imports the key with its fixed id+secret, grants `--read
--write`. Idempotent and **additive**.

> ⚠️ **Both storage nodes must be up.** Creating/deleting a bucket or key is a
> **global-metadata write** and needs cluster quorum. With one node down at the
> current 2-node size, the write fails `Could not reach quorum`. Do bucket/key
> admin only when `fleet buckets status` (or `garage status`) shows every node
> HEALTHY. (This eases to quorum 2/3 once node-c joins and rf=3 — see
> `01-garage-backup-implementation-plan.md`.)

### 4. Commit the encrypted secret

```bash
./scripts/fleet secrets      # choice 'v' verifies + stages s3-keys.enc.yaml
git commit -m "fleet: add velero bucket + key"
```

`secrets/s3-keys.enc.yaml` is committed **encrypted** (a flake copies only
git-tracked files; the values stay encrypted to the workstation key).

### 5. Hand the key to the consumer (prod repo)

Retrieve the plaintext to wire prod's k8s Secret + your password manager:

```bash
nix run .#sops -- -d secrets/s3-keys.enc.yaml
```

### Removing a bucket or key

`fleet buckets apply` is **additive** — it never prunes. Removing a line from the
spec does **not** delete anything live. Delete by hand on a node (needs quorum):

```bash
ssh root@<node>.<tailnet>.ts.net 'garage -c /etc/garage.toml key delete --yes <GK…>'
ssh root@<node>.<tailnet>.ts.net 'garage -c /etc/garage.toml bucket delete --yes <bucket>'
```

---

## Access a bucket with its key

All Garage listeners bind the node's `tailscale0` overlay IP only. S3 API =
port **3900**. Reach it from a tailnet peer (prod k8s is `tag:k8s → tag:garage
tcp:3900`; your workstation over the tailnet).

- **Endpoint**: `http://<node-tailscale-ip>:3900` (e.g. node-a `http://100.122.58.119:3900`)
- **Region**: `garage`
- **Addressing**: **path-style** (Garage does not do virtual-host buckets)

Get a key's id/secret:

```bash
nix run .#sops -- -d secrets/s3-keys.enc.yaml
```

### aws CLI

```bash
export AWS_ACCESS_KEY_ID=GK…             # e.g. cnpg-asp-key
export AWS_SECRET_ACCESS_KEY=…
aws --endpoint-url http://100.122.58.119:3900 --region garage \
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
endpoint = http://100.122.58.119:3900
region = garage
force_path_style = true
```

```bash
rclone ls   garage:cnpg-staging-asp
rclone tree garage:etcd-backup
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
