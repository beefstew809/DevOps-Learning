# AWS VPC and Networking

https://docs.aws.amazon.com/vpc/latest/userguide/

A VPC is a software-defined network you control: address range, subnets, routing, firewalls.
Almost every "it cannot connect" problem in AWS is one of five things, and this note is
mostly about identifying which.

## Structure

```
VPC  10.0.0.0/16                         regional; spans all AZs
├── AZ us-east-1a
│   ├── subnet 10.0.0.0/24   public      route 0.0.0.0/0 → Internet Gateway
│   └── subnet 10.0.10.0/24  private     route 0.0.0.0/0 → NAT Gateway
└── AZ us-east-1b
    ├── subnet 10.0.1.0/24   public
    └── subnet 10.0.11.0/24  private
```

**A subnet is public if and only if its route table sends `0.0.0.0/0` to an Internet
Gateway.** There is no "public" checkbox. That is the whole definition, and it is the first
thing to check when an instance cannot reach the internet.

Subnets are **AZ-scoped** — a subnet exists in exactly one AZ. Multi-AZ means one subnet per
AZ per tier.

## Addressing

Pick the CIDR carefully; **you cannot shrink a VPC's primary CIDR later** (you can add
secondary ranges).

```
10.0.0.0/16      65,536 addresses — the sane default for a VPC
10.0.0.0/24      256 addresses    — a reasonable subnet
```

AWS **reserves five addresses per subnet**: network address, VPC router (`.1`), DNS (`.2`),
future use (`.3`), and broadcast (`.255`). A `/24` gives 251 usable, and a `/28` gives 11 —
which is why very small subnets fail sooner than the arithmetic suggests.

Plan for non-overlapping ranges across VPCs and with on-premises. **Overlapping CIDRs cannot
be peered**, and discovering this after building both sides is an expensive migration. Give
each environment its own block from the start:

```
prod     10.0.0.0/16
staging  10.1.0.0/16
dev      10.2.0.0/16
```

See [../../Networking/networking-fundamentals.md](../../Networking/networking-fundamentals.md)
for CIDR arithmetic.

## Gateways

| Gateway | Direction | Notes |
| --- | --- | --- |
| **Internet Gateway** | Both ways | One per VPC, free. Needs a public IP on the resource |
| **NAT Gateway** | Outbound only | Managed, AZ-scoped, **~$32/mo + per-GB** |
| **Egress-only IGW** | Outbound only, IPv6 | Free — the IPv6 equivalent of NAT |
| **VPC endpoint** | To AWS services | Keeps traffic off NAT |
| **Transit Gateway** | VPC-to-VPC, hub | Scales past peering's mesh problem |

Two NAT Gateway facts that cost real money:

- **It is AZ-scoped.** One NAT Gateway serving three AZs means cross-AZ data transfer
  charges for two of them, plus a single point of failure. HA means one per AZ — three times
  the hourly cost.
- **Per-GB processing is charged on top of the hourly rate.** Pulling container images from
  ECR through NAT on every deploy is a line item people are genuinely surprised by.

### VPC endpoints pay for themselves

```bash
# Gateway endpoint — S3 and DynamoDB only, FREE, route-table based
aws ec2 create-vpc-endpoint --vpc-id vpc-abc \
  --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids rtb-private

# Interface endpoint — most other services, hourly + per-GB, ENI based
aws ec2 create-vpc-endpoint --vpc-id vpc-abc \
  --vpc-endpoint-type Interface \
  --service-name com.amazonaws.us-east-1.ecr.dkr \
  --subnet-ids subnet-private-a --security-group-ids sg-endpoints
```

The S3 gateway endpoint is free and removes S3 traffic from the NAT bill entirely. There is
no reason not to create it. For ECR you need `ecr.dkr`, `ecr.api` **and** the S3 endpoint —
ECR stores layers in S3, so missing the S3 one leaves image pulls going through NAT anyway.

## Security groups vs NACLs

This distinction causes real outages.

| | Security Group | Network ACL |
| --- | --- | --- |
| Attached to | ENI (instance, ALB, RDS) | Subnet |
| **State** | **Stateful** | **Stateless** |
| Rules | Allow only | Allow **and** Deny |
| Evaluation | All rules, any match allows | Numbered, first match wins |
| Default | Deny inbound, allow outbound | Allow everything |

**Stateful** means a security group that allows inbound 443 automatically allows the
response. **Stateless** means a NACL needs an explicit outbound rule for the return traffic —
and because replies go to **ephemeral ports (1024–65535)**, a NACL that allows inbound 443
but not outbound 1024–65535 breaks every connection in a way that looks like packet loss.

Guidance: **use security groups, leave NACLs at default-allow.** Reach for NACLs only for
coarse subnet-wide denial (blocking a CIDR). Debugging stateless rules is rarely worth it.

### Security groups can reference each other

The feature that makes them better than IP allow-lists:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-database \
  --protocol tcp --port 5432 --source-group sg-application
```

"Anything in `sg-application` may reach Postgres" — no IPs, no updates when instances change.
Build tiers this way:

```
sg-alb       inbound 443 from 0.0.0.0/0
sg-app       inbound 8080 from sg-alb
sg-database  inbound 5432 from sg-app
```

Note a security group referencing itself permits member-to-member traffic, which is what
cluster protocols need.

## Load balancers

| Type | Layer | Use |
| --- | --- | --- |
| **ALB** | 7 (HTTP) | Host/path routing, OIDC auth, WebSockets, gRPC |
| **NLB** | 4 (TCP/UDP) | Extreme throughput, static IPs, non-HTTP, TLS passthrough |
| **GWLB** | 3 | Inserting inline appliances |

Practical notes:

- **ALB needs at least two subnets in different AZs.** It refuses to create with one.
- Those subnets need **at least /27 and 8 free addresses** for the ALB's own ENIs.
- ALB has a security group; **classic NLB does not** (newer NLBs optionally do) — so for an
  NLB, the target's security group must allow the client CIDR directly, not the LB.
- `X-Forwarded-For` carries the real client IP behind an ALB. Configure your app and
  reverse proxy to trust it — see [../../reverse_proxy/nginx.md](../../reverse_proxy/nginx.md).
- **Health checks are the usual cause of 503s.** A target that is unhealthy receives no
  traffic; check the path, port, expected status code and that the security group permits the
  LB to reach it.

```bash
aws elbv2 describe-target-health --target-group-arn <arn>
```

`unused` means no registered targets; `unhealthy` with `Health checks failed` means the check
itself is wrong or the app is not listening where you think.

## DNS in a VPC

Two VPC attributes, both needed for private DNS to work:

```bash
aws ec2 modify-vpc-attribute --vpc-id vpc-abc --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id vpc-abc --enable-dns-hostnames
```

`enableDnsHostnames=false` is a common cause of RDS endpoints or interface endpoints not
resolving. Interface endpoints' private DNS depends on both.

Route 53 private hosted zones associate to VPCs and override public answers inside them.

## Connecting VPCs

| Option | Shape | Notes |
| --- | --- | --- |
| **Peering** | 1:1 | Free to create, **not transitive**, no overlapping CIDRs |
| **Transit Gateway** | Hub | Transitive, per-attachment hourly + per-GB |
| **PrivateLink** | Service exposure | Consumer reaches one service, no route merging |

"Not transitive" is the peering limitation that forces the migration: A↔B and B↔C does not
give A↔C. With more than about four VPCs the mesh becomes unmanageable and Transit Gateway
is the answer.

PrivateLink is the right tool when you want to *expose a service* rather than join networks —
no routing relationship, no CIDR coordination.

## Debugging: the five causes

When something cannot connect, it is almost always one of these. Check in order:

1. **Route table** — does the subnet have a route to the destination?
2. **Security group** — outbound on the source, inbound on the destination?
3. **NACL** — both directions, including ephemeral ports?
4. **Public IP** — a public-subnet resource still needs a public IP to use the IGW
5. **The application** — is it listening, and on the right interface?

```bash
# what route table does this subnet use, and what does it say?
aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=subnet-abc

# authoritative answer: AWS simulates the path for you
aws ec2 create-network-insights-path \
  --source i-0123456789abcdef0 --destination i-0fedcba9876543210 \
  --protocol tcp --destination-port 443
aws ec2 start-network-insights-analysis --network-insights-path-id nip-abc
aws ec2 describe-network-insights-analyses --network-insights-analysis-ids nia-abc
```

**Reachability Analyzer is the tool to reach for.** It evaluates routes, security groups and
NACLs statically and names the exact component that blocks the path — replacing an hour of
guessing with one answer.

For traffic that is flowing but wrong, enable **VPC Flow Logs**:

```
2 123456789012 eni-abc 10.0.1.5 10.0.10.20 49152 5432 6 10 840 1 REJECT OK
                                                              ^^^^^^ action
```

`REJECT` tells you a security group or NACL blocked it. No log line at all means the packet
never arrived — a routing problem, not a firewall one. That distinction is what flow logs are
for.

## A workable default layout

```
VPC 10.0.0.0/16, DNS support + hostnames on
  public  subnets in 3 AZs  (/24 each)  — ALB, NAT
  private subnets in 3 AZs  (/20 each)  — app, EKS nodes
  isolated subnets in 3 AZs (/24 each)  — RDS, no 0.0.0.0/0 route at all
  1 NAT Gateway per AZ for HA, or 1 total for cost in non-prod
  S3 + ECR(dkr, api) VPC endpoints
  Flow logs to CloudWatch or S3
  Security groups per tier, referencing each other
```

Private subnets get the larger `/20` because pod and node IPs consume addresses fast under
the EKS VPC CNI — each pod takes a real VPC address. Undersizing here is the most common
reason an EKS cluster stops scheduling. See [eks.md](eks.md).

## Related

- [aws-fundamentals.md](aws-fundamentals.md) — data transfer costs
- [eks.md](eks.md) — VPC CNI IP consumption
- [../../Networking/networking-fundamentals.md](../../Networking/networking-fundamentals.md) — CIDR, NAT, TCP
