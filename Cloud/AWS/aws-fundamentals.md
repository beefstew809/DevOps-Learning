# AWS Fundamentals

https://docs.aws.amazon.com/

The mental model that prevents most early confusion: AWS is hundreds of independent
services that share an identity system (IAM), a network model (VPC), and a billing model.
There is no "AWS" to learn — there is IAM, then the handful of services you actually use.

## Accounts, regions, availability zones

```
Organization
└── Account          ← the real isolation boundary. Blast radius, billing, quotas.
    └── Region       ← us-east-1, eu-west-2. Independent; most services are regional.
        └── AZ       ← us-east-1a. Separate datacenter(s), single-digit-ms apart.
```

**The account is the security boundary**, not tags or naming conventions. Serious setups
use separate accounts per environment (prod / staging / dev / shared-services) under AWS
Organizations, because an IAM mistake in dev then cannot touch prod. This is the single
most important structural decision.

**Regions are isolated.** A security group in `us-east-1` does not exist in `eu-west-1`.
Resources do not automatically replicate. Cross-region traffic costs money and adds
latency. Picking a region is about latency to users, data residency law, service
availability (new services land in `us-east-1` first) and price — which differs per region.

**AZ mapping is per-account.** Your `us-east-1a` is not necessarily the same physical AZ as
another account's `us-east-1a`. Use AZ *IDs* (`use1-az1`) when that matters.

A few services are global: IAM, Route 53, CloudFront, WAF (partly), and S3 bucket
namespacing. `us-east-1` is where their control planes live, which is why a `us-east-1`
outage can affect things elsewhere.

## The CLI

```bash
aws configure sso                     # preferred for humans
aws sso login --profile prod
aws configure --profile dev           # access keys; avoid for humans

aws sts get-caller-identity           # WHO AM I — run this constantly
aws sts get-caller-identity --profile prod
```

`aws sts get-caller-identity` is the most valuable command here. The common AWS accident is
running the right command in the wrong account. Check before anything destructive.

```bash
export AWS_PROFILE=dev                # beats passing --profile everywhere
aws ec2 describe-instances --region us-east-1 \
  --query 'Reservations[].Instances[].{id:InstanceId,type:InstanceType,state:State.Name}' \
  --output table
```

`--query` is JMESPath and runs client-side; `--filters` runs server-side and is cheaper on
large result sets. Use `--filters` to narrow, `--query` to shape.

```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

`--dry-run` on mutating EC2 calls tells you whether you *would* be permitted, without
acting — useful for checking IAM.

## Compute: choosing

| Service | Shape | Use when |
| --- | --- | --- |
| **EC2** | Virtual machines | You need the OS, or lift-and-shift |
| **ECS (Fargate)** | Containers, no nodes | Containers without wanting Kubernetes |
| **EKS** | Managed Kubernetes | You want Kubernetes, or portability |
| **Lambda** | Functions, event-driven | Short, spiky, glue work |
| **App Runner** | Container → URL | Simple web services |

The honest guidance: **if you do not already need Kubernetes, ECS on Fargate is less work
than EKS** — no node groups, no version upgrades, no CNI. EKS earns its cost when you want
the Kubernetes ecosystem (operators, Helm charts, ArgoCD) or portability off AWS. See
[eks.md](eks.md).

Lambda's constraints are the deciding factor: 15-minute max, 10 GB memory, cold starts,
and a programming model that punishes long-lived connections. Excellent glue, poor
application server.

### EC2 essentials

```bash
aws ec2 describe-instance-types --instance-types t3.medium \
  --query 'InstanceTypes[].{vcpu:VCpuInfo.DefaultVCpus,mem:MemoryInfo.SizeInMiB}'
```

Instance family naming decodes cleanly: `m7g.xlarge` = general purpose, gen 7, Graviton
(ARM), xlarge. `t` = burstable, `m` = balanced, `c` = compute, `r` = memory, `g`/`p` = GPU,
`i`/`d` = storage. A `g` in the suffix position means Graviton — **ARM, typically ~20%
cheaper for equal performance**, and the easy win if your images are multi-arch.

`t` family instances use CPU credits. Exhaust them and the instance throttles hard — this is
a classic "the app got slow for no reason" cause. `unlimited` mode trades throttling for a
surcharge.

Access instances with **SSM Session Manager**, not SSH:

```bash
aws ssm start-session --target i-0123456789abcdef0
```

No open port 22, no key management, no bastion, and every session is logged. Needs the SSM
agent (present on Amazon Linux and Ubuntu AMIs) and an instance profile with
`AmazonSSMManagedInstanceCore`. This is one of the clearest wins available.

## Storage, in one paragraph each

- **S3** — object storage. Effectively unlimited, 11 nines of durability, HTTP API. Not a
  filesystem; no partial writes, no rename (copy + delete).
- **EBS** — network block device for one EC2 instance. A disk. AZ-bound.
- **EFS** — NFS, shared across instances and AZs. Much slower and pricier than EBS per GB.
- **Instance store** — physical disk on the host. Fast, and **erased when the instance
  stops**.
- **Glacier classes** — archival tiers of S3 with retrieval delays measured in minutes to
  hours.

Detail in [storage-and-databases.md](storage-and-databases.md).

## Databases

| Service | Use |
| --- | --- |
| **RDS** | Managed Postgres/MySQL/MariaDB/SQL Server/Oracle |
| **Aurora** | AWS's Postgres/MySQL-compatible engine; faster failover, storage autoscaling |
| **DynamoDB** | Managed key-value/document; single-digit-ms, demands access-pattern-first design |
| **ElastiCache** | Managed Redis/Valkey/Memcached |

RDS removes patching, backups and failover — not schema design or query tuning. The
multi-AZ option is **standby for availability, not read scaling**; you cannot read from it.
Read replicas are a separate thing.

DynamoDB is excellent when the access patterns are known and fixed, and painful when they
change, because the partition key choice is effectively permanent. A relational database is
the safer default unless you specifically need DynamoDB's scale characteristics.

## Networking, briefly

Every non-trivial AWS setup is a VPC question. Covered in
[vpc-and-networking.md](vpc-and-networking.md), but the shape:

```
VPC 10.0.0.0/16
├── Public subnets    → route to Internet Gateway    (ALB, NAT)
└── Private subnets   → route to NAT Gateway         (app, database)
```

Public means "has a route to an Internet Gateway". That is the entire definition.

## Infrastructure as code

| Tool | Notes |
| --- | --- |
| **Terraform / OpenTofu** | Multi-cloud, huge ecosystem, explicit state. The common default. |
| **CloudFormation** | Native, no state file to manage, AWS-only, verbose |
| **CDK** | Real languages compiling to CloudFormation |
| **SAM** | CloudFormation shorthand for serverless |

Click-ops for anything permanent is the thing to avoid — not because consoles are bad for
exploring, but because nothing records what you did. Explore in the console, then write it
down as code. See [../../Infrastructure as Code/terraform/terraform-basics.md](../../Infrastructure%20as%20Code/terraform/terraform-basics.md).

## Cost: where the money actually goes

The surprises are rarely compute.

| Cost | Detail |
| --- | --- |
| **Data transfer out** | Inbound free; **outbound to internet costs per GB**. Cross-AZ traffic costs in both directions |
| **NAT Gateway** | ~$32/month each, **plus per-GB processing**. Often the largest line item in a small account |
| **Idle load balancers** | Charged hourly whether used or not |
| **Unattached EBS volumes** | Terminated instances leave volumes behind, billed forever |
| **Unassociated Elastic IPs** | Charged when *not* attached |
| **Old snapshots** | Accumulate silently |
| **CloudWatch Logs retention** | Defaults to **never expire** |
| **S3 incomplete multipart uploads** | Invisible in the console, billed |

Cross-AZ data transfer deserves emphasis: a chatty application spread across three AZs for
availability pays per-GB for its own internal traffic, in both directions. It is a real
architectural cost, not a rounding error.

```bash
# unattached volumes
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,size:Size,az:AvailabilityZone}' --output table

# unassociated elastic IPs
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'

# log groups with no retention policy
aws logs describe-log-groups \
  --query 'logGroups[?!retentionInDays].logGroupName' --output text
```

### Savings levers, roughly in order of effort

1. **Delete unused things.** Consistently the biggest win.
2. **Set CloudWatch log retention.** One API call per group.
3. **S3 lifecycle rules**, including aborting incomplete multipart uploads.
4. **Graviton** instances for ~20% off.
5. **Right-size.** Compute Optimizer makes recommendations from real utilisation.
6. **Savings Plans / Reserved Instances** for steady baseline load — 1 or 3 year
   commitment.
7. **Spot** for interruptible work (CI runners, batch) — up to 90% off, can vanish with two
   minutes' notice.
8. **VPC endpoints** to keep S3/ECR traffic off the NAT Gateway. Often pays for itself
   immediately.

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-08-01,End=2026-09-01 \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[].{svc:Keys[0],cost:Metrics.UnblendedCost.Amount}' \
  --output table
```

Set a **budget with an alert** on day one of any account. It is the only thing that turns a
runaway cost into a notification rather than an invoice.

## Well-Architected, compressed

The six pillars are a useful checklist even outside a formal review:

- **Operational excellence** — can you deploy, observe and roll back?
- **Security** — least privilege, encryption, audit.
- **Reliability** — what happens when an AZ fails? Have you tested restore?
- **Performance efficiency** — right service, right size.
- **Cost optimisation** — are you paying for idle?
- **Sustainability** — efficient use of what you provision.

The two questions that catch the most real problems: *what happens when this AZ goes away*,
and *have you restored from a backup recently*.

## Things that bite newcomers

- **`us-east-1` is special.** Global service control planes live there; it is also the
  busiest and most outage-prone region.
- **S3 bucket names are globally unique** across all AWS customers.
- **Deleting an account's resources does not stop the bill** until the resources are
  actually gone — check other regions, which the console hides by default.
- **Service quotas are per-region and low by default.** "Cannot launch instance" is often a
  quota, not capacity.
- **IAM is eventually consistent.** A new role may not be assumable for several seconds,
  which breaks tight automation.
- **Terminating an instance deletes its root EBS volume** (`DeleteOnTermination=true` by
  default) but leaves attached data volumes.
- **Tags are not permissions.** Tag-based access control exists but must be written
  explicitly; a tag alone restricts nothing.

## Related

- [iam.md](iam.md) — the service everything else depends on
- [vpc-and-networking.md](vpc-and-networking.md)
- [storage-and-databases.md](storage-and-databases.md)
- [eks.md](eks.md)
