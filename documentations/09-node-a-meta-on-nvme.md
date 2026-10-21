# 09 — node-A: Garage metadata on the NVMe

**Status:** config committed; one-shot migration via `scripts/node-a-meta-migrate`.

## Incident (2026-10-19)

B and C listed node-A under `FAILED NODES` for days although `garage.service`
was active and the tailnet was fine (`tailscale ping` 4–16 ms, `3901` open).
Garage on A accepted connections but answered RPC pings too late; even a local
`garage status` hung.

Cause — node-A was the only node with its LMDB metadata (`dpool/garage/meta`) on
the **single HDD**:

1. The weekly `zfs-scrub` of `dpool` (~40 h on this disk) pushed read latency to
   ~3 s average (`zpool iostat -l`: `total_wait` 3 s, scrub queue 6 s).
2. Devcontainers filled RAM + all 8 G of swap — a tmpfs `/tmp` in one container
   alone held 7.3 G — leaving < 1 G of page cache for a 54 G (with snapshots)
   LMDB. Every LMDB page fault went to the busy HDD.
3. LMDB is mmapped: a page fault blocks the garage runtime thread that took it,
   so pings stalled with it. Peers marked A failed; it flapped for the whole run.

Pausing the scrub (`zpool scrub -p dpool`) and freeing the container `/tmp` cut
latency but A still flapped while catching up on missed writes (~98 ms per small
HDD write). B and C keep meta on NVMe and were never affected.

## Fix (three parts)

| Part | Where | What |
|---|---|---|
| Meta on NVMe | `hosts/disko-node-a.nix` | new `wpool/garage-meta` → `/srv/garage/meta`: own encryptionroot, `keylocation=prompt`, **same passphrase as `dpool/garage`**, `nofail`, recordsize 16K, `quota=40G`. `dpool/garage/meta` removed from the layout. |
| Meta retention | `hosts/node-a.nix` | `wpool/garage-meta` in `fleet.sanoidDatasets` (moat + `garage-unlock`/`garage-status`), retention 24 h / 7 d / 0 m. LMDB churn pinned 82 G of meta snapshots at the full ladder; B/C each hold a full meta copy. |
| Contention | `modules/workstation.nix`, `hosts/node-a.nix` | `garage.service` `MemoryLow=2G`; `zfs_vdev_scrub_max_active=1`; scrub monthly (first Sunday 02:00) instead of weekly. |

What does NOT change: the TPM/PCR 7 seal (PCR 7 measures Secure Boot policy, not
datasets), the Garage node key (`node_key` is copied with the meta), layout,
`rpc_secret`, S3 keys, the boot path. No reboot is required. The manual gate is
unchanged too: meta stays ciphertext until `fleet unlock`, which feeds one
passphrase to every locked encryptionroot.

Space: `wpool` keeps its guarantees (`root` 30 G, `home` 200 G reserved; `docker`
quota 150 G). `wpool/garage-meta` draws from the shared slack, capped at 40 G.
⚠️ A full quota is LMDB ENOSPC — watch `zfs list -o used,quota wpool/garage-meta`.

## Runbook

Run from the workstation devcontainer (needs the real tailnet in the working
copy, like every deploy — doc 08).

```bash
nix flake check
scripts/node-a-meta-migrate status
scripts/node-a-meta-migrate migrate   # prompts for the dpool passphrase ONCE
scripts/fleet deploy node-a           # new fileSystems + MemoryLow; starts garage
```

`migrate` stops garage, proves the passphrase against `dpool/garage`, creates
`wpool/garage-meta` with it, rsyncs the meta (garage stopped → LMDB consistent),
verifies by checksum, then sets `dpool/garage/meta` `mountpoint=none` and
`wpool/garage-meta` `mountpoint=/srv/garage/meta`. Idempotent: rerun resumes.

Set the scrub priority live (the modprobe option applies at the next boot):

```bash
echo 1 | sudo tee /sys/module/zfs/parameters/zfs_vdev_scrub_max_active
```

Verify: `garage status` on A answers at once; B and C list A under
`HEALTHY NODES`; `cat /proc/pressure/io` on A drops; `zfs get mounted,mountpoint
wpool/garage-meta` = `yes /srv/garage/meta`.

## Rollback

```bash
scripts/node-a-meta-migrate rollback  # /srv/garage/meta back on dpool/garage/meta
git revert <this change> && scripts/fleet deploy node-a
```

Writes made after the migration exist only in `wpool/garage-meta`; A resyncs
them from B and C (rf=3). Destroying the old `dpool/garage/meta` (frees ~91 G of
HDD incl. snapshots) is a separate, irreversible step — only after A has been
stable for a few days.
