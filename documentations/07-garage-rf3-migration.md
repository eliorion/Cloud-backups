# 07 — Garage rf=2 → rf=3 migration (export, purge, restore)

Raise the cluster from `replication_factor = 2` to `3` so that **losing one node
leaves both reads and writes available**. At rf=2 the write quorum is 2, so a
single node outage stops every backup upload.

| | rf=2 (today) | rf=3 (target) |
|---|---|---|
| Quorum (`consistency_mode = "consistent"`) | W=2, R=1 | **W=2, R=2** |
| One node down → reads | works | works |
| One node down → **writes** | **FAILS** | **works** |
| Effective capacity | 1.3 TB | **700 GB** (smallest zone = node-A) |

> ⚠️ **There is no in-place path.** Garage's own reference manual: *"It is
> technically possible to change the replication factor although it's a dangerous
> operation that is **not officially supported**."* The only supported sequence is
> stop the whole cluster → delete `cluster_layout` on **every** node → change the
> config → restart → rebuild the layout → re-replicate. Verified against the
> Garage v2 configuration reference and layout docs (2026-08). There is no shortcut.

`consistency_mode` is NOT a substitute: at rf=2 both `consistent` and `degraded`
are W=2. Only `dangerous` gives W=1, which acknowledges a write held on a single
node — unacceptable for a DR vault.

---

## 1. The data-safety model: a VERIFIED S3 export is the restore path

**Garage holds the only copy of this data** (R2 was retired). Everything below
exists because a purge with no proven restore path is unacceptable.

The restore point is an **`rclone` export to an external S3 endpoint**, streamed
**S3 → S3** — nothing is staged on local disk, so no node spends space hosting it.

> **Why not ZFS snapshots?** An earlier revision of this doc used named
> `@pre-rf3` snapshots. They pin blocks and grow while the migration writes a
> third replica, consuming space on node-A. Deliberate operator trade: the
> export replaces them.
>
> **sanoid still runs** (`modules/zfs-sanoid.nix`: hourly 48, **daily 90**,
> monthly 3). The moat is intact — what is gone is a *pinned, named* point that
> pruning cannot reap. A same-day daily snapshot stays available for 90 days as a
> **last-resort** fallback (§6.2). The accepted cost: rollback is now
> "re-upload 146 GiB" (hours), not "`zfs rollback`" (seconds).

### ⚠️ Because it is the ONLY copy, verify at HASH level, not object counts

Matching object counts prove the *names* transferred. Only `rclone check
--checksum` proves the *bytes* did. §3 Gate 3 is not optional.

### ⚠️ The export target has no independence from prod

The staging endpoint (SeaweedFS, `tmp-backup-garage`) runs **on the prod Talos
cluster**, reached `direct 192.168.1.102` — the **same LAN as node-A**. So it has:

- **no trust-domain independence** — a prod compromise takes the live data *and*
  this copy, which is precisely what ADR-1 (doc 00 §4) exists to prevent;
- **no geographic independence** — one site event takes node-A and the copy;
- a **circular dependency** for `homelab-staging-etcd-backup` (doc 00 §5): etcd
  backups parked on the cluster whose etcd they back up.

Acceptable **only** as a temporary migration staging copy — the risk being
mitigated this week is "the purge corrupts Garage", not "prod is compromised".
**It must be deleted after the migration (§7).** It is not a second backup tier.

### ⚠️ CNPG objects are NOT client-side encrypted — wrap the export

Doc 00 §7 layer 1: client-side encryption covers the restic/Kopia paths (etcd,
Velero); **CNPG is the explicit exception**. `cnpg-staging-fbref` (127.7 GiB) is
plaintext Postgres backup data. Syncing it unencrypted onto the prod cluster puts
readable database contents exactly where a prod compromise reaches them.
**Wrap the destination in an `rclone crypt` remote.**

### Credential handling

The export endpoint's access/secret keys live in an rclone config **outside the
repo** (the workstation scratchpad), mode `0600`. This repo is PUBLIC. Note that
`.githooks/pre-commit` matches tailnet slugs, overlay IPs, ssh keys and 64-hex
secrets — it does **not** match a 32-hex S3 access key, so keeping these out of
the tree is manual discipline.

---

## 2. Baseline (re-capture immediately before starting — these numbers grow)

Recorded 2026-08-27:

| Bucket | Size | Objects |
|---|---|---|
| `cnpg-staging-fbref` | 127.7 GiB | 10 770 |
| `homelab-staging-etcd-backup` | 17.1 GiB | 117 |
| `cnpg-staging-ai-gateway` | 681.8 MiB | 2 871 |
| `cnpg-staging-nextcloud` | 168.1 MiB | 2 015 |
| `cnpg-staging-asp` | 0 B | 0 |
| `cnpg-staging-n8n` | 0 B | 0 |
| **TOTAL** | **~145.7 GiB** | **15 773** |

```bash
ssh root@node-a.<tailnet>.ts.net '
for b in $(garage -c /etc/garage.toml bucket list | tail -n +2 | awk "{print \$3}" | grep -v "^$"); do
  printf "%-30s " "$b"
  garage -c /etc/garage.toml bucket info "$b" | grep -E "^(Size|Objects):" | tr -s " " | tr "\n" "|"; echo
done'
```

---

## 3. Pre-flight gates — ALL must pass, in order

### Gate 0 — Export target readiness

1. Confirm the destination bucket has **≥160 GiB** free (146 + headroom). If it is
   Longhorn-backed on the prod cluster, check the underlying PVC, not just the
   bucket.
2. Write the rclone config to the workstation scratchpad, `chmod 0600`. Never in
   this repo. Path-style addressing; endpoint `https://seaweedfs-s3.<tailnet>.ts.net`.
3. Add an **`rclone crypt`** remote wrapping that bucket (§1).
4. Round-trip one small object through the crypt remote: put → read back →
   checksum → delete. **Gate:** checksum matches.

### Gate 1 — Drive integrity errors to zero (BEFORE exporting)

A cluster with referenced blocks in error would export its own inconsistency.
As of 2026-08-27 node-A had **2 referenced (RC>0) blocks in error**, with Garage
reporting `inconsistencies between the block_ref and the version tables`.

```bash
ssh root@node-a.<tailnet>.ts.net '
  garage -c /etc/garage.toml repair --yes block-refs
  garage -c /etc/garage.toml repair --yes --all-nodes blocks
  garage -c /etc/garage.toml repair --yes --all-nodes tables'
```

**Gate:** on all three nodes,
`garage block list-errors | tail -n +2 | awk '$2>0' | wc -l` returns **0**.
Unreferenced (RC=0) entries are GC-pending and acceptable.

### Gate 2 — Prove the source is intact before copying it

```bash
ssh root@node-a.<tailnet>.ts.net 'garage -c /etc/garage.toml repair --yes --all-nodes scrub'
# poll until scrub-last-completed advances on every node:
for n in node-a node-b node-c; do
  ssh root@$n.<tailnet>.ts.net 'garage -c /etc/garage.toml worker get | grep -i scrub'
done
```

**Gate:** `scrub-corruptions_detected = 0` on node-A, node-B and node-C.
Then re-capture the §2 baseline.

### Gate 3 — Export, and verify it at hash level

1. `rclone sync` each of the six buckets → the crypt remote. Point the source at
   node-A's S3 endpoint (`http://<node-a-ip>:3900`, region `garage`, path-style):
   it holds roughly half the partitions locally and streams the rest from B/C.
2. **`rclone check --checksum`** per bucket. Names and sizes are not enough.
3. **Restore rehearsal — prove the RESTORE direction, not just the backup one.**
   Restore a sample from the crypt remote into a **scratch Garage bucket** and
   checksum against the originals. Include at least one object from
   `cnpg-staging-fbref` (largest) and one from `homelab-staging-etcd-backup`
   (most critical). Delete the scratch bucket afterwards.

**Gate:** zero differences from `rclone check --checksum` on all six buckets, and
the rehearsal checksums match. **Do not proceed past this line until it passes.**

### Gate 4 — Everything else

1. **Let the layout v2 rebalance FINISH.** Never stack a purge on in-flight
   partition transfers (`garage status`; node-B's partition count stable).
2. **Prove node-A's boot path is untouched.** node-A is the only node with LUKS +
   TPM2 (PCR 7) + Secure Boot. Build the proposed closure on node-A and diff it
   **without activating**:
   ```bash
   nix store diff-closures /run/current-system /nix/store/<new-toplevel>
   ```
   If kernel / initrd / lanzaboote inputs are unchanged, no new UKI is signed,
   PCR 7 cannot move, and the TPM keyslot is safe. **If the diff shows a new
   kernel, stop** and schedule node-A separately with the LUKS recovery
   passphrase physically to hand.
   > This procedure never reboots node-A — deploy-rs activates via `switch` and
   > only `garage.service` is stopped/started. PCR 7 is consulted at boot only, so
   > the risk is deferred to node-A's *next* boot, not this window.
3. **Capacity.** rf=3 at maximum zone redundancy makes effective capacity the
   smallest zone: node-A at 700 GB vs 145.7 GiB used (~4.8× headroom). Re-confirm.
4. **Secrets to hand:** node-A LUKS recovery passphrase, all ZFS passphrases,
   per-node root passwords (`fleet status` vault section).
5. **Pause the backup jobs** — Flux CRs in the PROD repo (etcd CronJob, CNPG
   ObjectStore, Velero), not here. The cluster goes fully offline; unpaused jobs
   will error and retry into a dead endpoint.
6. **Working tree:** `flake.nix`, `modules/base.nix`, `hosts/node-b.nix` carry real
   values and MUST stay dirty/uncommitted. `.githooks/pre-commit` enforces this.

---

## 4. Migration

### 4.1 Change the config (workstation)

`modules/garage.nix` is shared by every host — one edit, three deploys:

```nix
replication_factor = 3;
consistency_mode = "consistent";   # rf=3 → W=2 / R=2
```

Update the comment block above it: the current text describes the rf=2 interim and
its "pool empty, DR data re-pushable" justification, which is **no longer true**.

```bash
nix flake check          # must pass before anything reaches a node
```

### 4.2 Stop the cluster

```bash
for n in node-a node-b node-c; do
  ssh root@$n.<tailnet>.ts.net 'systemctl stop garage; systemctl is-active garage'
done
```
An explicit `stop` does not trigger `Restart=`, so they stay down.

### 4.3 Restore point

**No named ZFS snapshot is taken** (§1). The restore point is the verified export
from Gate 3, plus sanoid's automatic daily snapshots as a last resort.

**Confirm Gate 3 passed before continuing.** This is the point of no cheap return.

### 4.4 Purge `cluster_layout` on ALL nodes

Rename, never delete — and keep a copy off the dataset:

```bash
for n in node-a node-b node-c; do
  ssh root@$n.<tailnet>.ts.net '
    cp /srv/garage/meta/cluster_layout /root/cluster_layout.rf2.bak
    mv /srv/garage/meta/cluster_layout /srv/garage/meta/cluster_layout.rf2.bak
    ls -la /srv/garage/meta/ | grep cluster_layout'
done
```

### 4.5 Deploy rf=3 to all three

node-B first (LAN-reachable, so a mistake is recoverable), then node-C, node-A last:

```bash
./scripts/fleet deploy node-b -- --remote-build
./scripts/fleet deploy node-c -- --remote-build
./scripts/fleet deploy node-a -- --remote-build
```

Activation starts `garage.service`. With `cluster_layout` gone and the config at
rf=3, it starts clean instead of hitting the rf-mismatch refusal.

> If activation fails and magic-rollback reverts, that node returns to the rf=2
> config while its `cluster_layout` is already purged — it will then crash-loop
> exactly as node-B did on 2026-08-27. Recoverable: re-deploy, or restore the
> `.bak` (§6.3). Do not panic-reboot.

### 4.6 Rebuild the layout

A purged cluster starts fresh at **version 1**:

```bash
ssh root@node-a.<tailnet>.ts.net '
  garage -c /etc/garage.toml layout assign <id-A> -z onsite    -c 700GB
  garage -c /etc/garage.toml layout assign <id-B> -z offsite-1 -c 1000GB
  garage -c /etc/garage.toml layout assign <id-C> -z offsite-2 -c 1000GB
  garage -c /etc/garage.toml layout show'          # review the staged plan
ssh root@node-a.<tailnet>.ts.net '
  garage -c /etc/garage.toml layout apply --version 1'
```

Node IDs: `garage -c /etc/garage.toml node id -q` on each node, or `fleet layout show`.
Confirm the staged plan reports **"Partitions are replicated 3 times on at least 3
distinct zones"** before applying.

### 4.7 Re-replicate

Going 2 → 3 copies means a third copy of every partition must be built.

```bash
ssh root@node-a.<tailnet>.ts.net 'garage -c /etc/garage.toml repair --help'
# run the applicable repair operations (blocks, tables); confirm exact
# subcommands against --help on 2.1.0 rather than assuming them.
```

Expect hours-to-days over the WAN for ~146 GiB. The cluster **is** available during
this (degraded), unlike §4.2–4.6.

> Do **not** run block GC until §5 passes. A half-rebuilt layout plus GC is how
> blocks get discarded.

---

## 5. Verification — the acceptance test

1. **Layout:** `garage layout show` reports 3 nodes, 3 zones, version 1.
2. **Inventory matches the §2 baseline** — bucket count, object counts, sizes.
   Counts must be **≥** baseline (jobs may have run), never lower.
3. **Integrity:** re-run Gate 2's scrub; `scrub-corruptions_detected = 0` on all three.
4. **THE ACTUAL GOAL — one node down, read AND write both work:**
   ```bash
   ssh root@node-b.<tailnet>.ts.net 'systemctl stop garage'   # simulate an outage
   aws --endpoint-url http://<node-a-ip>:3900 --region garage s3 ls s3://<bucket>/
   echo rf3-write-test | aws --endpoint-url http://<node-a-ip>:3900 --region garage \
        s3 cp - s3://<bucket>/rf3-write-test.txt
   ssh root@node-b.<tailnet>.ts.net 'systemctl start garage'
   ```
   **Both must succeed.** At rf=2 the write fails — that failure is the entire
   reason for this migration. Delete the test object afterwards.
5. **Moat intact:** `zfs allow dpool/garage` must show the `garage` user NOWHERE
   (doc 00 §7). Re-audit after the migration.
6. Un-pause the Flux backup jobs; confirm the next etcd snapshot and CNPG WAL push land.

---

## 6. Restore

### 6.1 PRIMARY — restore from the verified S3 export

Used if the migration corrupts or loses object data.

```bash
# 1. stop garage everywhere
for n in node-a node-b node-c; do
  ssh root@$n.<tailnet>.ts.net 'systemctl stop garage'; done

# 2. bring the cluster back up on a known-good config + layout (§6.3 or a
#    re-deploy), then recreate buckets and keys declaratively:
./scripts/fleet buckets apply          # doc 06 — idempotent, the reprovision path

# 3. sync back from the crypt remote (reverse of Gate 3), per bucket
rclone --config <scratchpad>/rclone-export.conf sync \
       crypt:<bucket> garage:<bucket> --checksum

# 4. reconcile block references, then verify
ssh root@node-a.<tailnet>.ts.net '
  garage -c /etc/garage.toml repair --yes --all-nodes blocks
  garage -c /etc/garage.toml repair --yes --all-nodes tables'
```

**Verify:** object counts and sizes match the §2 baseline; `rclone check --checksum`
reports no differences; scrub reports zero corruptions.

Expect hours — this is the cost accepted in §1 for not pinning ZFS snapshots.

### 6.2 LAST RESORT — sanoid's automatic daily snapshot

No named `@pre-rf3` snapshot exists, but sanoid retains **daily snapshots for 90
days**. A same-day daily is a viable rollback point at ~24 h granularity.

```bash
ssh root@<node>.<tailnet>.ts.net 'zfs list -t snapshot | grep garage | grep daily'
```

⚠️ Three hazards, all load-bearing:

- **The dataset list differs per node.** node-A keeps `meta` **and** `data` under
  `dpool/garage`; node-B and node-C keep `meta` + ssd data on **`npool`** and hdd
  data on **`dpool`**. Rolling back only `dpool` on B/C restores bulk data with
  **no metadata to interpret it**.
- **`zfs rollback` does not recurse into children.** Roll back the leaf datasets
  (`…/data`, `…/meta`) individually, not just the parent.
- **`zfs rollback -r` destroys every snapshot newer than the target** — irreversible.

`meta` and `data` are separate datasets (separate *pools* on B/C) and are **NOT
crash-consistent together** (`modules/zfs-sanoid.nix:58-61`). After any rollback
you **MUST** reconcile:

```bash
ssh root@<node>.<tailnet>.ts.net 'garage -c /etc/garage.toml repair --yes --all-nodes blocks'
```

Rolling back the metadata dataset also restores that node's `cluster_layout`.

### 6.3 Layout is wrong, data is fine

Do not restore anything. Put the saved layout back:

```bash
ssh root@<node>.<tailnet>.ts.net '
  systemctl stop garage
  mv /srv/garage/meta/cluster_layout.rf2.bak /srv/garage/meta/cluster_layout
  systemctl start garage'
```

### 6.4 node-A will not boot (TPM/PCR-7 rotated)

Unrelated to Garage, but this window is when you would discover it. Use the
**keyslot-0 LUKS recovery passphrase** at the console, then re-enrol the TPM per
`modules/secureboot.nix`. This is why Gate 4.2 exists.

---

## 7. Post-migration cleanup

- **DELETE THE STAGING EXPORT.** 146 GiB of DR data — including CNPG objects that
  are plaintext at source — must not linger on the prod cluster (§1). Do this only
  after §5 passes in full.
- Remove the `.bak` layout files:
  `rm /srv/garage/meta/cluster_layout.rf2.bak /root/cluster_layout.rf2.bak`
  (also node-B's older `cluster_layout.rf1.bak` from the 2026-08-27 rejoin).
- Update `modules/garage.nix`'s comment block and the README status table
  (rf 2 → 3; effective capacity 1.3 TB → 700 GB).

---

## 8. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Export incomplete or silently corrupt | Low | **Critical** — it is the only copy | Gate 3 `rclone check --checksum` + restore rehearsal into a scratch bucket |
| Exporting an already-inconsistent cluster | **Medium** | High | Gate 1 drives referenced block errors to 0; Gate 2 scrub proves integrity first |
| Staging copy is on prod, same LAN as node-A | Certain | Medium | Accepted as temporary only; deleted at §7; not a second backup tier |
| Plaintext CNPG data exposed on prod | **Medium** | High | `rclone crypt` remote (§1); prompt deletion (§7) |
| Rollback is slow (no pinned snapshot) | Certain | Medium | Accepted trade (§1); sanoid dailies remain as §6.2 fallback |
| §6.2 fallback rolled back on the wrong datasets | Medium | **High** | Per-node dataset hazards spelled out in §6.2 |
| node-A TPM unlock breaks | Low | High | Gate 4.2 closure diff; no reboot in this procedure; recovery passphrase to hand |
| Magic-rollback reverts one node mid-migration | Medium | Medium | Node crash-loops but data is untouched; re-deploy or §6.3 |
| Backup jobs error during the window | High | Low | Suspend the Flux CRs first (Gate 4.5) |
| Block GC discards data mid-rebuild | Low | **High** | No GC until §5 passes |

---

## See also

- `documentations/00-garage-backup-cluster.md` §4 (ADR-1, trust domains), §5 (layout,
  circular dependency), §7 (the moat, and which paths are client-side encrypted)
- `documentations/06-garage-buckets-guide.md` — buckets/keys for Gate 3 and §6.1
- `modules/garage.nix` — `replication_factor`, and the stale rf=2 comment to update
- `modules/zfs-sanoid.nix` — retention, and the meta/data consistency caveat behind §6.2
