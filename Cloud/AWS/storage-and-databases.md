# AWS Storage and Databases

https://docs.aws.amazon.com/s3/

Also the general cloud-storage note: the object vs block vs file distinction below applies to
every provider, and choosing wrongly is expensive to undo.

## Object vs block vs file

| | Object (S3) | Block (EBS) | File (EFS) |
| --- | --- | --- | --- |
| Interface | HTTP API | Raw device | NFS |
| Unit | Whole object | Blocks | Files and directories |
| Partial write | **No** — rewrite the object | Yes | Yes |
| Shared access | Many readers/writers | One instance | Many instances |
| Capacity | Unlimited | Fixed, provisioned | Elastic |
| Cost per GB | Cheapest | Middle | Most expensive |
| Latency | ~10s of ms | sub-ms | low ms |

The consequences that matter in design:

- **Object storage has no partial update and no rename.** Changing one byte means rewriting
  the object; "renaming" is copy-then-delete. A database cannot live on S3 directly for this
  reason.
- **Block storage attaches to one machine.** It does not scale horizontally — see the RWO
  discussion in [../../Container Orchestration/kubernetes/kubernetes-storage.md](../../Container%20Orchestration/kubernetes/kubernetes-storage.md).
- **File storage is the compatibility option**: existing software expects a filesystem. You
  pay for that in latency and cost.

Default to object storage for anything new that can use it — it is cheapest, most durable, and
has no capacity planning.

## S3

```bash
aws s3 ls
aws s3 ls s3://my-bucket/prefix/ --recursive --human-readable --summarize
aws s3 cp file.txt s3://my-bucket/
aws s3 sync ./local s3://my-bucket/backup/ --delete
aws s3 presign s3://my-bucket/file.pdf --expires-in 3600
```

`aws s3` (high level) vs `aws s3api` (one call per API action). Use `s3` for moving data,
`s3api` for anything configuration-shaped.

**Bucket names are globally unique across all AWS customers** and DNS-compatible: lowercase,
no underscores, 3–63 characters.

### Consistency

S3 has been **strongly read-after-write consistent** since December 2020 for all operations.
Older material describing eventual consistency, and the workarounds built for it, is obsolete.
A successful `PutObject` is immediately readable.

### Storage classes

| Class | Use | Retrieval |
| --- | --- | --- |
| `STANDARD` | Active data | Immediate |
| `INTELLIGENT_TIERING` | Unknown/changing patterns | Immediate |
| `STANDARD_IA` | Infrequent, needs immediate access | Immediate |
| `ONEZONE_IA` | Reproducible data | Immediate, **one AZ** |
| `GLACIER_IR` | Archive, instant retrieval | Immediate |
| `GLACIER` | Archive | Minutes to hours |
| `DEEP_ARCHIVE` | Compliance, cheapest | **Up to 12 hours** |

The traps:

- **Minimum storage durations are billed regardless.** 30 days for IA, 90 for Glacier, 180
  for Deep Archive. Deleting a Deep Archive object after a week bills 180 days.
- **Minimum billable object size is 128 KB** for IA and Glacier classes. A million 4 KB
  objects in IA costs more than in Standard.
- **Retrieval costs money** on IA and Glacier, per GB. Frequently-read IA data is more
  expensive than Standard.
- `ONEZONE_IA` has no cross-AZ redundancy — fine for thumbnails you can regenerate, wrong for
  backups.

Intelligent-Tiering is the right default when you do not know the access pattern: it moves
objects between tiers automatically for a small monitoring fee per object (which makes it a
poor fit for huge numbers of tiny objects).

### Lifecycle rules

```json
{
  "Rules": [
    {
      "Id": "archive-and-expire-logs",
      "Status": "Enabled",
      "Filter": { "Prefix": "logs/" },
      "Transitions": [
        { "Days": 30, "StorageClass": "STANDARD_IA" },
        { "Days": 90, "StorageClass": "GLACIER" }
      ],
      "Expiration": { "Days": 365 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket my-bucket --lifecycle-configuration file://lifecycle.json
```

Two clauses that are pure savings and almost always missing:

- **`AbortIncompleteMultipartUpload`** — failed uploads leave parts that are billed and
  invisible in the console. Every bucket should have this.
- **`NoncurrentVersionExpiration`** — with versioning on, deletes do not free space. Old
  versions accumulate forever without this.

```bash
# find the invisible cost
aws s3api list-multipart-uploads --bucket my-bucket
```

### Versioning and deletion

```bash
aws s3api put-bucket-versioning --bucket my-bucket \
  --versioning-configuration Status=Enabled
```

Versioning makes `DELETE` insert a **delete marker** rather than removing data — so deletion
is recoverable, and storage keeps growing. It cannot be switched off, only suspended.

For backups, add **Object Lock** (requires versioning, set at bucket creation):

```bash
aws s3api put-object-retention --bucket my-backups --key db.dump \
  --retention '{"Mode":"COMPLIANCE","RetainUntilDate":"2027-01-01T00:00:00Z"}'
```

`COMPLIANCE` mode cannot be removed by anyone, including the root account, until it expires.
That is the property that makes a backup ransomware-resistant — an attacker with full admin
still cannot delete it. `GOVERNANCE` mode allows override with a specific permission.

### Security

Four things, in order:

```bash
# 1. Block public access — account-wide, then per bucket
aws s3control put-public-access-block --account-id 123456789012 \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 2. Disable ACLs entirely; use policies
aws s3api put-bucket-ownership-controls --bucket my-bucket \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

# 3. Default encryption
aws s3api put-bucket-encryption --bucket my-bucket \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms",
      "KMSMasterKeyID":"alias/s3"},"BucketKeyEnabled":true}]}'

# 4. Require TLS
```

```json
{
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"],
  "Condition": { "Bool": { "aws:SecureTransport": "false" } }
}
```

`BucketKeyEnabled: true` with SSE-KMS cuts KMS request costs dramatically — without it, every
object operation is a billed KMS call.

Serving content publicly should go through **CloudFront with an Origin Access Control**, not a
public bucket: cheaper egress, caching, and the bucket stays private.

### Performance

S3 scales to 5,500 reads and 3,500 writes per second **per prefix**, so parallelism comes from
spreading keys across prefixes. Random or hashed prefixes were once required and are not any
more, but prefix spread still governs throughput.

```bash
aws configure set default.s3.max_concurrent_requests 20
aws configure set default.s3.multipart_chunksize 16MB
```

For many small files, `aws s3 sync` is slow because each object is a round trip. Tarring
first, or using `s5cmd`, is often an order of magnitude faster.

## EBS

| Type | Use | Notes |
| --- | --- | --- |
| `gp3` | **Default for everything** | 3,000 IOPS and 125 MB/s baseline, independently scalable |
| `gp2` | Legacy | IOPS tied to size — migrate to gp3 |
| `io2` Block Express | Critical databases | Up to 256,000 IOPS, 99.999% durability |
| `st1` | Throughput, sequential | Big logs, data processing. Poor random IO |
| `sc1` | Cold | Cheapest |

**`gp3` over `gp2`, always.** It is cheaper per GB and you can buy IOPS without buying
capacity. On gp2 the only way to get more IOPS was a bigger volume.

```bash
aws ec2 modify-volume --volume-id vol-abc --volume-type gp3 --iops 6000
```

Online, no downtime. The filesystem still needs growing after a size change
(`growpart` + `resize2fs`/`xfs_growfs`).

Facts worth holding:

- Volumes are **AZ-bound.** Moving one means snapshot → create in the new AZ.
- Snapshots are incremental and go to S3, but **each is independently complete** — deleting an
  old snapshot does not break newer ones.
- `DeleteOnTermination` is **true for root volumes** and false for attached data volumes.
  Hence the orphaned-volume cost in [aws-fundamentals.md](aws-fundamentals.md).
- Encryption is set at creation and **cannot be toggled**. Migrate via snapshot → encrypted
  copy → new volume. Set an account-level default so you never have to.

```bash
aws ec2 enable-ebs-encryption-by-default
```

## EFS

NFS, multi-AZ, elastic. Reach for it when several machines genuinely need the same
filesystem.

```bash
aws efs create-file-system --performance-mode generalPurpose \
  --throughput-mode elastic --encrypted
```

- `throughput-mode elastic` is the modern default. Old `bursting` mode ties throughput to
  stored size, so a near-empty filesystem is very slow — a confusing performance cliff.
- **Needs a mount target per AZ**, each with a security group permitting 2049 from clients.
- **Latency is much higher than EBS.** Workloads doing many small IOs — git repositories,
  `node_modules`, SQLite — perform badly.
- Infrequent Access lifecycle saves a lot on cold files.
- **Access points** pin a POSIX UID/GID and subdirectory per application, which is the clean
  way to share one filesystem between workloads.

## RDS and Aurora

```bash
aws rds describe-db-instances \
  --query 'DBInstances[].{id:DBInstanceIdentifier,engine:Engine,class:DBInstanceClass,multiaz:MultiAZ}' \
  --output table
```

What managed actually means: patching, backups, failover, replication. Not schema design,
indexing, query tuning, or connection management.

| Concept | Reality |
| --- | --- |
| **Multi-AZ** | Synchronous standby for **availability**. You cannot read from it |
| **Read replica** | Asynchronous, readable, separate endpoint, replica lag |
| **Automated backups** | Daily snapshot + 5-minute transaction logs → point-in-time restore |
| **Manual snapshots** | Kept until you delete them |
| **Restore** | Creates a **new instance**; you then repoint the app |

That last row catches people during an incident: you cannot restore in place. Recovery means
a new endpoint, so the runbook must include repointing — and therefore the connection string
must be somewhere changeable (parameter store, DNS CNAME), not baked into an image.

- **Automated backups are deleted with the instance.** Take a final manual snapshot before
  deleting anything.
- **The default backup retention is 1 day** (7 via console). Set it deliberately.
- **Connection limits scale with instance size.** A small instance plus serverless
  functions exhausts connections fast; use RDS Proxy or a pooler.
- **Performance Insights** is the first place to look for a slow database, and is free at
  7-day retention.
- **Aurora Serverless v2** scales in 0.5 ACU steps and suits spiky or dev workloads; it does
  not scale to zero except in specific configurations.

## Encryption and KMS

```bash
aws kms create-key --description "app data"
aws kms create-alias --alias-name alias/app-data --target-key-id <id>
```

- **AWS-managed keys** (`aws/s3`) are free and simple, but you cannot control their policy or
  audit grants finely.
- **Customer-managed keys** cost ~$1/month plus per-request, and let you write a key policy,
  rotate on a schedule, and revoke.
- Encrypted resources need **both** the service permission and `kms:Decrypt`. Missing the
  latter gives an AccessDenied that does not mention KMS — see [iam.md](iam.md).
- **Deleting a key is irreversible** after the 7–30 day waiting period, and takes all data
  encrypted with it. Use disable rather than delete unless you are certain.
- Cross-account and cross-region use needs grants or a multi-region key.

## Picking storage

```
Needs a filesystem, one machine?            EBS gp3
Needs a filesystem, many machines?          EFS (accept the latency)
Objects over HTTP, any size, any amount?    S3
Archive, rarely read?                       S3 Glacier / Deep Archive + lifecycle
Relational?                                 RDS (Aurora if you need fast failover)
Key-value at scale, fixed access patterns?  DynamoDB
Cache or session store?                     ElastiCache
Scratch space, can be lost?                 Instance store
```

## Related

- [aws-fundamentals.md](aws-fundamentals.md)
- [iam.md](iam.md) — the two-ARN S3 pattern and KMS permissions
- [../../Backups/backup-strategy.md](../../Backups/backup-strategy.md) — Object Lock, restore testing
- [../../Container Orchestration/kubernetes/kubernetes-storage.md](../../Container%20Orchestration/kubernetes/kubernetes-storage.md)
