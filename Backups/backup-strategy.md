# Backup Strategy

The only fact that matters: **a backup you have not restored is not a backup.** It is an
untested assumption with storage costs. Most backup failures are discovered during the first
real restore, which is the worst possible time to learn the format is wrong, the key is gone, or
the job has silently failed for four months.

## Define the requirements first

Two numbers drive every other decision:

| Term | Question | Determines |
| --- | --- | --- |
| **RPO** — Recovery Point Objective | How much data may we lose? | Backup **frequency** |
| **RTO** — Recovery Time Objective | How long may recovery take? | Backup **method and storage tier** |

A 24-hour RPO means daily backups. A 15-minute RPO means continuous archiving or replication. An
RTO of one hour rules out restoring 2 TB from Glacier Deep Archive, which can take 12 hours just
to begin.

State them per service, not globally. Photo storage and a password manager do not need the same
guarantees, and pretending they do makes the whole plan too expensive to maintain.

Add a third: **retention**. How far back must you be able to go? Ransomware and slow corruption
are the reason this is longer than it intuitively needs to be — if the only copies are from after
the compromise, they are all compromised.

## 3-2-1, and why

```
3 copies of the data
2 different media or systems
1 off-site
```

Modern extension — **3-2-1-1-0**: one copy **immutable or offline**, and **zero errors on
verification**.

The immutable copy is the answer to ransomware, which now deliberately targets backups. If the
backup system can be reached with the same credentials as production, it is part of the same
blast radius. Concretely:

- S3 **Object Lock** in `COMPLIANCE` mode — not deletable by anyone, including root, until
  expiry. See [../Cloud/AWS/storage-and-databases.md](../Cloud/AWS/storage-and-databases.md).
- A restic repository with **append-only** credentials, so the backup client cannot delete
  history.
- A pull-based model: the backup server reaches into hosts, rather than hosts pushing and
  therefore holding delete rights.

**A snapshot is not a backup.** Storage snapshots usually live in the same system as the data, so
they do not survive that system failing, being deleted, or being encrypted by someone with
admin. They are fast rollback — valuable, and a different thing.

**Replication is not a backup either.** A replica faithfully reproduces `DROP TABLE`.

## What to actually back up

The common mistake is backing up the wrong layer — capturing the application files and not the
state, or the state and not the knowledge needed to use it.

| Category | Examples | Notes |
| --- | --- | --- |
| **Databases** | Postgres, MySQL, SQLite | Needs a consistent dump, not a file copy |
| **User data** | Uploads, photos, documents | Usually the largest and least reproducible |
| **Configuration** | Compose files, manifests, Ansible | Should be in git — verify git is backed up |
| **Secrets** | `.env`, Vault unseal shares, sealing keys | Lose these and the data is unusable |
| **Metadata** | Container labels, volume names, DNS, firewall rules | The "how it was wired" knowledge |

That last two rows are the ones people omit and then cannot restore. Specifically:

- **Vault unseal shares** — a Raft snapshot is encrypted; without the shares it is noise.
- **Sealed Secrets sealing key** — without it, every sealed secret in git is permanently
  undecryptable.
- **SOPS/age private keys.**

Back these up **separately from the data they protect**, or a single compromise takes both.

Things *not* to back up: container images (rebuild from the registry), `node_modules`, caches,
OS packages, anything reproducible from code. Backing them up inflates cost and restore time for
no recovery benefit.

## Databases need a dump, not a file copy

Copying a live database's files produces a torn, probably unusable image. Use the engine's tool.

**PostgreSQL**

```bash
# logical, portable, per-database
pg_dump -Fc -d mydb -f mydb-$(date +%F).dump
pg_restore -d mydb --clean --if-exists mydb-2026-09-12.dump

# everything including roles and globals — needed for a full rebuild
pg_dumpall --globals-only > globals.sql

# physical + WAL archiving for point-in-time recovery (low RPO)
pg_basebackup -D /backup/base -Ft -z -X stream
```

`pg_dumpall --globals-only` is the commonly forgotten half: a `pg_dump` restores schemas and data
but not the roles they depend on, so the restore fails on missing users.

For a real low RPO you need **continuous archiving** (`archive_command` + base backups) so you can
recover to any moment, not just the last dump. `pgBackRest` or `barman` manage this properly;
hand-rolled WAL archiving is easy to get subtly wrong.

**MySQL/MariaDB**

```bash
mysqldump --single-transaction --routines --triggers --events \
  --all-databases | gzip > all-$(date +%F).sql.gz
```

`--single-transaction` gives a consistent snapshot without locking (InnoDB). Omitting
`--routines --triggers --events` silently drops stored procedures — a restore that looks fine
until something calls one.

**SQLite**

```bash
sqlite3 app.db ".backup '/backup/app-$(date +%F).db'"
```

Use `.backup`, not `cp`. A plain copy of a database mid-write is corrupt, and SQLite is
everywhere in self-hosted software.

**In containers**

```bash
docker exec -t postgres pg_dump -Fc -U app mydb > mydb.dump
docker exec -t postgres sh -c 'pg_dump -Fc -U app mydb' | gzip > mydb.dump.gz
```

Run the dump *inside* the container so versions match. A newer `pg_dump` on the host against an
older server, or vice versa, can fail or produce an unrestorable file.

## Verification: the part that is usually missing

Three levels, in increasing value:

1. **Did the job run?** Exit code, a log line, a freshness check. Necessary and insufficient.
2. **Is the artifact intact?** Checksum, `restic check`, `pg_restore --list`.
3. **Does it restore?** Actually restore it somewhere and query the result.

Only level 3 is a real test. Automate it:

```bash
#!/usr/bin/env bash
set -euo pipefail

LATEST=$(ls -t /backup/*.dump | head -1)

# restore into a throwaway container
podman run -d --name verify -e POSTGRES_PASSWORD=x docker.io/library/postgres:17
until podman exec verify pg_isready -q; do sleep 1; done

podman exec -i verify createdb -U postgres verify
podman exec -i verify pg_restore -U postgres -d verify < "$LATEST"

# assert something real about the data, not just that restore exited 0
ROWS=$(podman exec verify psql -U postgres -d verify -tAc 'SELECT count(*) FROM users')
podman rm -f verify

[ "$ROWS" -gt 0 ] || { echo "RESTORE VERIFY FAILED: users table empty"; exit 1; }
echo "verified: $LATEST, $ROWS users"
```

The row-count assertion matters. A restore can exit 0 having produced an empty schema.

**Alert on backup age, not on backup failure.** A failure alert depends on the job running to
report it; a cron that stopped firing reports nothing at all. Age is the signal that catches both:

```promql
time() - backup_last_success_timestamp_seconds > 26 * 3600
```

This is the single highest-value backup alert. Silent cessation is the most common real failure —
the job broke months ago and nobody noticed because nothing ever failed loudly.

## Restore runbooks

Write the restore procedure **before** you need it, and keep it with the backups rather than only
in the system being restored.

```markdown
## Restore: app database

**RTO 1h, RPO 24h.** Backups: s3://backups/pg/, 30 daily + 12 monthly, Object Lock 35d.
Encryption key: 1Password item "backup age key" — ALSO in the offline safe.

1. Provision Postgres 17 (same major version — a dump does not restore to an older one)
2. `aws s3 cp s3://backups/pg/latest.dump.age .`
3. `age -d -i key.txt latest.dump.age > latest.dump`
4. `pg_dumpall --globals-only` from backup, apply FIRST (roles must exist)
5. `pg_restore -d app --clean --if-exists latest.dump`
6. Verify: `SELECT count(*) FROM users;` — expect ~40k
7. Repoint the app: update the connection string in <where> and restart
8. Check the app's own health endpoint

**Last tested: 2026-08-20, took 22 minutes.**
```

That last line is the most important in the document. An untested runbook is a guess, and the
recorded duration is what makes the RTO real rather than aspirational.

Restore **drills** quarterly, at minimum annually. Schedule them; they do not happen otherwise.

## Tooling

| Tool | Shape |
| --- | --- |
| **restic** | Deduplicating, encrypted, many backends, snapshot model. Excellent default |
| **borgbackup** | Similar, very efficient dedup, weaker remote-backend support |
| **Kopia** | Similar, good UI |
| **rclone** | Sync, not backup — no history or dedup unless paired |
| **Velero** | Kubernetes objects + PV snapshots |
| **pgBackRest** | Postgres PITR done properly |

See [restic-and-restore-testing.md](restic-and-restore-testing.md).

A note on `rclone` and `aws s3 sync`: they mirror, so **a deletion or encryption on the source
propagates to the destination on the next run.** Without versioning or Object Lock on the target,
a sync-based "backup" offers no protection against the failure mode that matters most.

## Kubernetes

Two things to capture, and they are separate:

- **Objects** — ideally already in git as the source of truth; GitOps makes cluster rebuild a
  re-sync. See [../GitOps/gitops-principles.md](../GitOps/gitops-principles.md).
- **PersistentVolume data** — git has the PVC definition, not the contents.

```bash
velero install --provider aws --bucket my-backups --use-node-agent
velero backup create nightly --include-namespaces prod --wait
velero restore create --from-backup nightly
velero backup describe nightly --details
```

Velero's `--use-node-agent` (file-level copy) works on any storage; CSI snapshots are faster but
stay within the storage system and are not off-site on their own.

For databases in Kubernetes, prefer an application-level dump to a Job with a PVC snapshot — the
dump is consistent and portable across versions and clusters.

## Cost control

Backups grow forever unless retention is enforced.

- **Tiered retention**: 7 daily, 4 weekly, 12 monthly, 3 yearly. Covers both "I deleted that an
  hour ago" and "this was corrupted months ago".
- **Lifecycle rules** to move old backups to cold storage — but check the retrieval time against
  your RTO before archiving anything you might need quickly.
- **Deduplication** (restic/borg) typically makes daily full backups cost little more than
  incrementals.
- **Compress before encrypting.** Encrypted data does not compress.
- Watch storage minimums: deleting a Glacier object early still bills 90 or 180 days.

## Checklist

- [ ] RPO, RTO and retention written down, per service
- [ ] 3 copies, 2 media, 1 off-site, 1 immutable
- [ ] Databases dumped with the engine's tool, not file-copied
- [ ] Secrets and keys backed up **separately** from the data they unlock
- [ ] Encrypted in transit and at rest; **decryption key recoverable independently**
- [ ] Automated restore verification asserting something about the data
- [ ] Alert on backup **age**
- [ ] Restore runbook written, with a last-tested date and duration
- [ ] Backup credentials cannot delete history (append-only or Object Lock)
- [ ] Retention enforced so cost does not grow without bound

## Related

- [restic-and-restore-testing.md](restic-and-restore-testing.md)
- [../Cloud/AWS/storage-and-databases.md](../Cloud/AWS/storage-and-databases.md) — Object Lock, storage classes
- [../Container Orchestration/kubernetes/kubernetes-storage.md](../Container%20Orchestration/kubernetes/kubernetes-storage.md)
- [../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md)
