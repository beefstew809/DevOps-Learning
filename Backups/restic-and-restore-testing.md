# restic and Restore Testing

https://restic.readthedocs.io/

A single static binary that does deduplicating, encrypted, incremental backups to local disk,
SFTP, S3 and a dozen other backends. It is a good default because the properties that matter are
on by default: **everything is encrypted client-side**, and deduplication means daily snapshots
cost little more than the changes.

## Model

```
repository        the destination — encrypted, content-addressed
└── snapshots     point-in-time, each a full logical view
      └── blobs   deduplicated chunks shared across all snapshots
```

Every snapshot behaves like a full backup when you restore it, while storing only new chunks.
There is no full/incremental distinction to manage, and no chain to break.

## Setup

```bash
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/my-backups/docker1"
export RESTIC_PASSWORD_FILE="/root/.restic-password"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

restic init
```

**The repository password is the encryption key.** Lose it and the repository is
unrecoverable — there is no recovery mechanism, by design. Store it in a password manager *and*
somewhere offline, and never only on the machine being backed up.

Add a second key so one lost password is survivable:

```bash
restic key add          # adds another valid password
restic key list
```

Other backends:

```bash
RESTIC_REPOSITORY="sftp:backup@nas.example.internal:/backups/docker1"
RESTIC_REPOSITORY="rest:https://restic.example.internal/docker1"
RESTIC_REPOSITORY="/mnt/nfs/backups/docker1"
```

The **REST server** backend is the one worth knowing for a homelab: it supports
`--append-only`, so a compromised client can add snapshots but cannot delete history. That is the
immutability property from
[backup-strategy.md](backup-strategy.md) without needing S3 Object Lock.

## Backing up

```bash
restic backup /etc /home /var/lib/app \
  --exclude-caches \
  --exclude-file=/etc/restic/excludes.txt \
  --tag nightly \
  --host docker1

restic snapshots
restic snapshots --tag nightly --latest 5
```

```
# /etc/restic/excludes.txt
**/node_modules
**/.cache
**/*.tmp
/var/lib/docker/overlay2
/proc
/sys
/dev
```

`--exclude-caches` honours `CACHEDIR.TAG`, which many tools write. Excluding
`/var/lib/docker/overlay2` matters — it is large, churns constantly, and is reproducible from
images.

### Backing up a database correctly

Do not back up the data directory. Stream a dump into restic with `--stdin`:

```bash
docker exec -t postgres pg_dump -Fc -U app mydb | \
  restic backup --stdin --stdin-filename "mydb.dump" --tag postgres
```

This keeps consistency (the engine produces the dump) and deduplication still applies across
nightly dumps, because most chunks repeat.

For several databases, loop and tag each:

```bash
for db in app analytics; do
  docker exec -t postgres pg_dump -Fc -U app "$db" | \
    restic backup --stdin --stdin-filename "$db.dump" --tag "pg-$db"
done
```

## Restoring

```bash
# inspect before restoring
restic snapshots
restic ls latest
restic ls latest /etc/nginx
restic find '*.conf'
restic diff <snap1> <snap2>

# restore
restic restore latest --target /restore
restic restore latest --target /restore --include /etc/nginx
restic restore <snapshot-id> --target /
```

For a database dumped via `--stdin`:

```bash
restic dump latest mydb.dump | pg_restore -d mydb --clean --if-exists
```

`restic dump` streams a single file to stdout, which avoids staging a large dump on disk.

### Mounting is the best feature

```bash
mkdir /mnt/restic
restic mount /mnt/restic
# browse /mnt/restic/snapshots/latest/... with normal tools
```

A FUSE filesystem of every snapshot. This turns "which version of this file do I want" into
`ls` and `diff` instead of repeated restores. It is also the fastest way to recover one file.

## Maintenance

Two separate operations, and the distinction matters:

```bash
# 1. mark snapshots for removal per a retention policy
restic forget \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3 \
  --tag nightly --group-by host,tags --dry-run

# 2. actually reclaim space
restic prune
```

`forget` only removes snapshot references. **`prune` is what frees storage** by repacking data
files. Running `forget` without `prune` means retention appears to work while the repository
keeps growing.

`--group-by host,tags` applies the policy per host and tag rather than across everything —
without it, one noisy host's snapshots can consume another's retention slots.

Always `--dry-run` a new `forget` policy first. It deletes.

### Integrity checks

```bash
restic check                        # structure and metadata — fast
restic check --read-data            # re-reads and verifies EVERY blob — slow, expensive on S3
restic check --read-data-subset=5%  # sample; good weekly compromise
```

`restic check` alone validates the index, not the data. `--read-data-subset=5%` weekly is the
practical middle ground and catches bit rot or a backend silently losing objects.

### Locks

An interrupted run leaves a lock and later runs refuse to start:

```bash
restic list locks
restic unlock                  # only after confirming nothing is actually running
```

Check for a running process before unlocking — two concurrent `prune`s can damage a repository.

## Automating with systemd

A timer is preferable to cron: it logs to the journal, supports `OnFailure=`, and does not need
mail configured.

```ini
# /etc/systemd/system/restic-backup.service
[Unit]
Description=restic backup
OnFailure=restic-alert@%n.service

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/bin/restic backup /etc /home /var/lib/app \
  --exclude-file=/etc/restic/excludes.txt --tag nightly
ExecStart=/usr/bin/restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 \
  --group-by host,tags --prune
ExecStart=/bin/sh -c 'echo "backup_last_success_timestamp_seconds $(date +%%s)" > /var/lib/node_exporter/textfile/restic.prom'
```

```ini
# /etc/systemd/system/restic-backup.timer
[Unit]
Description=Nightly restic backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
chmod 600 /etc/restic/env
systemctl enable --now restic-backup.timer
systemctl list-timers restic-backup.timer
journalctl -u restic-backup.service -n 50
```

Three details:

- `Persistent=true` runs a missed job after the host was off, rather than skipping the day.
- `IOSchedulingClass=idle` keeps the backup from starving the services it is backing up.
- That last `ExecStart` writes a metric for node-exporter's textfile collector, which makes the
  **backup-age alert** from [backup-strategy.md](backup-strategy.md) possible. Without a freshness
  metric you cannot detect a timer that silently stopped firing.

```ini
# /etc/systemd/system/restic-alert@.service — fires only on failure
[Service]
Type=oneshot
ExecStart=/usr/bin/curl -s -d "restic failed on %H: %i" https://ntfy.example.com/alerts
```

## Automated restore testing

The step that converts backups into recoverable backups. Run it on a schedule, not by hand.

```bash
#!/usr/bin/env bash
# /usr/local/bin/restic-verify
set -euo pipefail
source /etc/restic/env

fail() { echo "VERIFY FAILED: $*" >&2; exit 1; }

# 1. repository structure intact, plus a data sample
restic check --read-data-subset=5% || fail "restic check"

# 2. is the newest snapshot actually recent?
LATEST_TS=$(restic snapshots --json --latest 1 --tag nightly | jq -r '.[0].time')
AGE_H=$(( ( $(date +%s) - $(date -d "$LATEST_TS" +%s) ) / 3600 ))
[ "$AGE_H" -lt 26 ] || fail "newest snapshot is ${AGE_H}h old"

# 3. restore a known file and compare content
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
restic restore latest --target "$TMP" --include /etc/hostname
grep -q . "$TMP/etc/hostname" || fail "restored /etc/hostname is empty"

# 4. restore the database dump into a throwaway instance and query it
restic dump latest mydb.dump > "$TMP/mydb.dump" || fail "dump extract"

podman run -d --rm --name rverify -e POSTGRES_PASSWORD=x docker.io/library/postgres:17 >/dev/null
trap 'podman rm -f rverify >/dev/null 2>&1; rm -rf "$TMP"' EXIT
until podman exec rverify pg_isready -q 2>/dev/null; do sleep 1; done

podman exec rverify createdb -U postgres verify
podman exec -i rverify pg_restore -U postgres -d verify < "$TMP/mydb.dump" || fail "pg_restore"
ROWS=$(podman exec rverify psql -U postgres -d verify -tAc 'SELECT count(*) FROM users')
[ "${ROWS:-0}" -gt 0 ] || fail "users table empty after restore"

echo "OK: snapshot ${AGE_H}h old, ${ROWS} users restored"
echo "backup_verify_success_timestamp_seconds $(date +%s)" \
  > /var/lib/node_exporter/textfile/restic-verify.prom
```

Weekly via a timer, with `OnFailure=` alerting. Every check asserts something specific:
the repository is readable, the snapshot is fresh, a file restores with content, and the
database restores with **rows in it**. A restore that exits 0 with an empty schema passes the
first three and fails the fourth — which is precisely the failure worth catching.

## Performance

```bash
restic backup /data --read-concurrency 4
restic prune --max-repack-size 5G        # bound a long prune
restic --pack-size 64 backup /data       # fewer, larger files — better for S3
restic --verbose=2 backup /data          # see what is being read
```

A first backup is slow (everything is new); later ones are fast. If later backups stay slow, the
usual cause is a directory full of churn that should be excluded, or scanning a mount that is
remote.

restic's cache lives in `~/.cache/restic`. Deleting it forces re-downloading metadata — do not
put it on a tmpfs that clears on reboot.

## Pitfalls

| Pitfall | Consequence |
| --- | --- |
| Password only on the backed-up host | Host dies, backups are unreadable |
| `forget` without `prune` | Storage grows forever |
| No `--group-by` | One host's retention consumes another's |
| Backing up a live DB directory | Torn, unrestorable data |
| Client credentials can delete | Ransomware deletes the backups too — use append-only |
| `restic check` only, never `--read-data` | Bit rot undetected |
| No freshness metric | A stopped timer is silent |
| Never restore-tested | Discovering the problem during the outage |

## Related

- [backup-strategy.md](backup-strategy.md) — RPO/RTO, 3-2-1-1-0, runbooks
- [../Observability/logging-and-alerting.md](../Observability/logging-and-alerting.md) — alerting on age
- [../Cloud/AWS/storage-and-databases.md](../Cloud/AWS/storage-and-databases.md) — Object Lock, lifecycle
