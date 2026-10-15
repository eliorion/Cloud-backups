# 08 — node-A dpool full: shrink sanoid retention (GitOps fix)

Incident 2026-10-15, and the fix: retention lives in `modules/zfs-sanoid.nix`, is
changed in git, deployed with `fleet deploy`, and sanoid's own autoprune reclaims
the space. No hand-run `zfs destroy`.

## 1. What happened

| When (UTC) | Event |
|---|---|
| 2026-09-24 17:56 | node-A HDD logs READ/WRITE I/O errors (`zpool status`: 2 R / 2 W). Scrub on 10-12 repaired 0 B. |
| 2026-10-15 ~03:00 | Nightly CNPG base backup of `cnpg-staging-fbref` (~18 GiB) lands on a 96%-full pool |
| 2026-10-15 03:41–03:56 | `txg_sync blocked for more than 245 seconds` (pool at 0 B free) |
| 2026-10-15 04:08 | garage: `LMDB: No space left on device (os error 28)` |
| 2026-10-15 14:00 | sanoid: `cannot create snapshots : out of space` — moat stops taking snapshots |

Effect: rf=2, so every partition with a replica on node-A (133 of 256) cannot be
written: `503 Could not reach quorum of 2`. CNPG WAL archiving from prod fails
for those objects; prod Postgres retains the WAL until the archive catches up.

## 2. Why so much is stored

Live Garage data is only ~260 G per node. **Snapshots hold 2–3× that:**

| dataset | live | held by snapshots |
|---|---|---|
| A `dpool/garage/data` | 262G | 603G |
| A `dpool/garage/meta` | 0.6G | 32.8G |
| B `dpool` + `npool` data | 357G | 589G |
| C `dpool` + `npool` data | 366G | 759G |

Two multipliers stack:

1. **Snapshot space ≈ churn × retention.** CNPG takes a *full* base backup every
   night and archives WAL continuously; its retention policy then deletes old
   ones. Garage deletes the blocks, but every daily snapshot taken while a block
   was live keeps it on disk. With `daily = 90` and `monthly = 3`, each deleted
   block survived up to 3 months.
2. **The churn itself is large** — see §2.1: `cnpg-staging-fbref` is
   406 GiB logical of the cluster's ~460 GiB.

`garage/meta` is worse in ratio (~50×): LMDB is copy-on-write and
`metadata_auto_snapshot_interval = "6h"` rewrites the DB copy 4×/day, so each
ZFS snapshot pins a fresh ~0.5 G.

### 2.1 `cnpg-staging-fbref` breakdown

Full listing 2026-10-15 (74 291 objects):

| prefix | objects | size |
|---|---|---|
| `fbref-db-v2/wals/` | 74 239 | **279.3 GiB** (gzip'd, ~2.4 MB per 16 MB segment) |
| `fbref-db-v2/base/` (9 complete) | | 8.7 → 17.9 GiB each, growing |
| `fbref-db-v2/base/` (11 with only `backup.info`) | | 0 — **failed base backups** |

WAL uploaded per day (GiB, compressed):

| Aug 16–24 | Sep | Oct 07 | Oct 08 | Oct 09 | Oct 10 | Oct 11 | Oct 12 | **Oct 13** | **Oct 14** |
|---|---|---|---|---|---|---|---|---|---|
| 0.4–7 | ≤ 4.3 | 5.8 | 13.7 | 7.0 | 8.1 | 20.9 | 31.8 | **66.6** | **80.4** |

**The fbref database started writing ~10–20× more WAL from Oct 11** (80 GiB/day
compressed ≈ 34 000 segments ≈ 530 GiB/day raw, for a ~18 GiB database). That
is the real driver: node-A holds 133/256 partitions, so it takes ~42 GiB/day of
new blocks, and every one of them stays pinned by snapshots for the retention
window even after CNPG prunes it.

> ⚠️ **Retention alone does not fix this.** At 42 GiB/day × 30 days the
> steady-state snapshot footprint on node-A would be ~1.2 TB — more than the
> disk. The ~268G that §3 reclaims buys **about 6 days** at the Oct-14 rate.
> At the Aug–Sep rate (≤ 4 GiB/day) 30 days fits comfortably. The WAL rate must
> come down on the prod side (§7).

## 3. The fix (in git)

`modules/zfs-sanoid.nix`, template `garage` (all storage nodes):

| | before | after |
|---|---|---|
| hourly | 48 | 48 |
| daily | 90 | **30** |
| monthly | 3 | **2** |

Measured with sanoid's own planner (`sanoid --prune-snapshots --readonly` on
each node against the new config) + `zfs destroy -nv` on the exact list:

| node | snapshots pruned | reclaimed |
|---|---|---|
| node-A | 124 | data 258G + meta 10.1G |
| node-B | 75 | dpool 66.3G + npool data 28.6G + meta 8.0G |
| node-C | 186 | dpool 181G + npool data 77.7G + meta 13.2G |

node-A goes from 0 B to ~268G free; node-C `npool` from 8.3G to ~99G.

> ⚠️ **Irreversible trade.** Pruned snapshots are gone. The ransomware rollback
> window shrinks from 90 days to **30 days** (+ the Sep and Oct monthlies). A
> mass-delete must now be noticed within 30 days. Garage is the only copy of
> this data.

## 4. Runbook

From the workstation devcontainer, on the branch carrying the change.

```bash
# 1. Verify the change evaluates (3 nodes, same template)
for n in node-a node-b node-c; do
  nix eval --json .#nixosConfigurations.$n.config.services.sanoid.templates.garage
done   # → "daily":30, "monthly":2
nix flake check

# 2. Already committed on this branch (retention + comments + this doc).
#    Commit BY NAME only — the tree carries the real tailnet; never git add -A.

# 3. Deploy — node-A first (the wedged one), then C (8 G left), then B
scripts/fleet deploy node-a
scripts/fleet deploy node-c
scripts/fleet deploy node-b
```

> ⚠️ **Before each deploy, the working copy must hold the node's REAL values.**
> The committed `hosts/node-*.nix` carry scrubbed placeholders (`tailscaleIp =
> "100.64.0.1x"`, `aaaa…`/`bbbb…` peer ids). Deploying them makes garage bind an
> address the node does not have: `Cannot assign requested address`, then a panic
> at `netapp.rs:208` and a restart loop. This is what broke the first node-A
> deploy on 2026-10-15. Restore the real values in the working copy (never
> commit them), then diff the built config against the live one:
>
> ```bash
> p=$(nix build --no-link --print-out-paths .#nixosConfigurations.node-c.config.system.build.toplevel)
> diff <(ssh root@node-c cat /etc/garage.toml) $p/etc/garage.toml && echo identical
> ```

Intended change is only `sanoid.conf`. On a node whose pool is already full,
garage cannot restart either (`ExecStartPre` `chown … No space left on device`),
so prune first if the deploy restarts it.

```bash
# 4. Prune now instead of waiting for the hourly timer
ssh root@node-a systemctl start sanoid.service
ssh root@node-a 'journalctl -u sanoid -n 30 --no-pager'
```

## 5. Verify

```bash
ssh root@node-a 'zfs list -o name,used,usedbysnapshots,avail -r dpool/garage'   # avail ≈ 268G
ssh root@node-a garage stats      # node-a DataAvail/MetaAvail > 0, resync queue draining
ssh root@node-a 'journalctl -u garage --since -10min | grep -c "No space left"'   # → 0
ssh root@node-a 'zfs list -t snapshot -r dpool/garage/data | tail -2'          # new hourly taken
ssh root@node-a 'zfs list -H -t snapshot -o name -r dpool/garage/data | grep -c _daily'  # ≤ 30
```

Prod side (prod repo, not here): CNPG `ContinuousArchiving` condition back to
`True`, `kubectl cnpg status` shows the WAL archive caught up.

Repeat the checks on node-B/-C after their deploy.

## 6. Rollback

`git revert` + `fleet deploy` restores the 90/3 policy for **future** snapshots.
Snapshots already pruned cannot come back.

## 7. Follow-ups (not in this change)

- Separate sanoid template for `*/garage/meta` (e.g. daily 7) — meta churn is
  ~50× its size.
- An empty `reservation` dataset per pool, so a future ENOSPC is undone with
  one `zfs set reservation=none` instead of a deploy.
- `health-alert.nix`: add a pool-capacity check (> 85%) and enable it — nothing
  alerted on this incident.
- node-A HDD I/O errors: SMART check (`smartctl` is not installed) / burn-in
  before the rf=3 migration (doc 07).
- **Prod repo, urgent:** find what makes `fbref` write ~530 GiB/day of WAL since
  Oct 11 (bulk re-scrape/upsert loop, `VACUUM FULL`, reindex, unlogged→logged
  churn…) and why base backups fail (11 of 20 have only `backup.info`). While
  archiving fails, prod keeps the WAL in `pg_wal` — check that PVC is not filling.
