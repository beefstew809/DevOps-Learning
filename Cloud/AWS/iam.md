# AWS IAM

https://docs.aws.amazon.com/IAM/latest/UserGuide/

Every AWS API call is authenticated and authorized by IAM. Get this wrong and nothing else
matters — IAM misconfiguration is the leading cause of cloud compromise, usually via
long-lived access keys.

## The evaluation logic

For each request, AWS collects every applicable policy and evaluates:

```
1. Explicit DENY anywhere?          → DENY. Nothing overrides this.
2. Organizations SCP permits?       → no: DENY
3. Resource policy / session / permission boundary permits?
4. Identity policy ALLOWs?          → yes: ALLOW
5. Otherwise                        → DENY (default)
```

Two rules to memorise: **default is deny**, and **an explicit Deny always wins**. A user
with `AdministratorAccess` is still denied anything an SCP or permission boundary denies —
which is how you constrain even admins.

## Principals

| Principal | Use |
| --- | --- |
| **Role** | The answer almost always. Assumed temporarily, credentials expire. |
| **User** | A human or legacy app with long-lived credentials. Minimise. |
| **Group** | A collection of users; attach policies here, not to users |
| **Service-linked role** | AWS service acting on your behalf |

**Roles over users, always.** A role has no permanent credentials — `sts:AssumeRole` returns
keys that expire in an hour. There is nothing to leak long-term.

The end state worth aiming for: **zero IAM users**. Humans authenticate via IAM Identity
Center (SSO) and assume roles; workloads use instance profiles, IRSA, or OIDC federation.
The only common exception is a legacy system that genuinely cannot assume a role.

```bash
aws iam list-users                    # ideally empty
aws iam list-access-keys --user-name legacy-app
```

## Policy anatomy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadAppBucket",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-app-data",
        "arn:aws:s3:::my-app-data/*"
      ],
      "Condition": {
        "IpAddress": { "aws:SourceIp": "203.0.113.0/24" }
      }
    }
  ]
}
```

`"Version": "2012-10-17"` is a policy language version, not a date you choose. Always that
string.

**The two-ARN pattern for S3 is the most common IAM mistake.** Bucket-level actions
(`ListBucket`, `GetBucketLocation`) act on `arn:aws:s3:::bucket`; object-level actions
(`GetObject`, `PutObject`) act on `arn:aws:s3:::bucket/*`. They are different resources.
Grant only the first and listing works but downloads fail with AccessDenied; grant only the
second and the reverse.

### ARN shape

```
arn:aws:service:region:account-id:resource
arn:aws:s3:::my-bucket                              (S3: no region or account)
arn:aws:iam::123456789012:role/deploy               (IAM: global, no region)
arn:aws:ec2:us-east-1:123456789012:instance/i-abc
```

### Policy types

| Type | Attached to | Notes |
| --- | --- | --- |
| **Identity-based** | User, group, role | The usual kind |
| **Resource-based** | S3 bucket, KMS key, SQS queue | Can grant cross-account without a role |
| **Permission boundary** | User or role | Maximum possible permissions; does not grant |
| **SCP** | OU or account | Org-wide ceiling; does not grant |
| **Session policy** | Passed at AssumeRole | Further narrows that session |

The three that only *restrict* — boundary, SCP, session policy — are how you delegate safely.
Let a team create roles, but attach a boundary so the roles they create cannot exceed it.

## Trust policies

A role has two policies: what it **can do** (permissions) and **who can assume it** (trust).
Forgetting the trust policy is why `AssumeRole` returns AccessDenied on a role with correct
permissions.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

Cross-account, with the conditions that make it safe:

```json
{
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111122223333:root" },
  "Action": "sts:AssumeRole",
  "Condition": {
    "StringEquals": { "sts:ExternalId": "unique-shared-value" },
    "Bool": { "aws:MultiFactorAuthPresent": "true" }
  }
}
```

`"Principal": {"AWS": "...:root"}` means *any principal in that account*, not the root user —
a naming choice that misleads constantly. The account's own IAM still has to allow the call,
so it is a two-sided grant.

**`ExternalId` matters for third parties.** Without it, a vendor with many customers can be
tricked into using your role on another customer's behalf — the confused deputy problem. Any
SaaS asking you to create a role should supply one.

## Workload identity: the point of all this

Stop storing credentials. Each compute platform has a native mechanism:

**EC2 — instance profile.** Credentials from the instance metadata service:

```bash
# from on the instance; IMDSv2, token required
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

Enforce **IMDSv2** (`HttpTokens: required`). IMDSv1's unauthenticated GET is what made SSRF
into credential theft in several well-known breaches.

**EKS — IRSA or Pod Identity.** A Kubernetes ServiceAccount maps to an IAM role; see
[eks.md](eks.md).

**Lambda / ECS** — execution and task roles, automatic.

**CI — OIDC federation.** No stored keys at all:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:myorg/myrepo:ref:refs/heads/main"
    }
  }
}
```

Scope `sub` tightly. `StringLike` with `repo:myorg/*` trusts every repo in the org, and a
pattern matching `pull_request` lets a fork's PR assume the role. Use `StringEquals` on an
exact ref where you can.

## Least privilege, practically

Starting from `*` and narrowing never happens. Starting from nothing and adding does.

```bash
# what a principal actually used in the last N days
aws iam get-service-last-accessed-details --job-id <id>

# generate a policy from CloudTrail history — the best starting point
aws accessanalyzer start-policy-generation \
  --policy-generation-details principalArn=arn:aws:iam::123456789012:role/myrole
```

`iam:PassRole` deserves specific attention. It lets a principal hand a role to a service —
so a user who can `PassRole` an admin role to Lambda and create functions is effectively
admin. Always constrain it:

```json
{
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": "arn:aws:iam::123456789012:role/app-runtime-*",
  "Condition": {
    "StringEquals": { "iam:PassedToService": "lambda.amazonaws.com" }
  }
}
```

Other escalation paths worth knowing, each of which turns limited access into admin:
`iam:CreatePolicyVersion`, `iam:AttachUserPolicy`, `iam:UpdateAssumeRolePolicy`,
`lambda:UpdateFunctionCode` on a privileged function, and `ec2:RunInstances` combined with
`PassRole`.

## Testing instead of guessing

```bash
# would this principal be allowed?
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/myrole \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::my-bucket/file.txt

# validate a policy document before applying
aws accessanalyzer validate-policy --policy-document file://policy.json --policy-type IDENTITY_POLICY

# what is publicly or cross-account reachable
aws accessanalyzer list-findings --analyzer-arn <arn>
```

IAM Access Analyzer findings are the fastest way to discover an accidentally public bucket
or an over-broad cross-account trust.

## Reading an AccessDenied

The message usually names everything you need:

```
User: arn:aws:sts::123456789012:assumed-role/myrole/session is not authorized to
perform: s3:GetObject on resource: arn:aws:s3:::bucket/key
because no identity-based policy allows the s3:GetObject action
```

The trailing clause is the useful part:

| Clause | Fix |
| --- | --- |
| `no identity-based policy allows` | Add the action to the role's policy |
| `with an explicit deny in a resource-based policy` | Bucket policy / KMS key policy |
| `with an explicit deny in a service control policy` | SCP at the OU — you cannot fix this locally |
| `with an explicit deny in a permissions boundary` | Boundary on the role |

No clause at all usually means a missing `kms:Decrypt` on an encrypted resource — the S3
call is allowed but the object cannot be decrypted. Encrypted buckets need **both** S3 and
KMS permissions, and that second requirement is easy to miss.

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --max-results 10
```

## Audit checklist

```bash
# root account access keys — should be none, ever
aws iam get-account-summary --query 'SummaryMap.AccountAccessKeysPresent'

# users without MFA
aws iam list-users --query 'Users[].UserName' --output text | \
  xargs -n1 -I{} sh -c 'test -z "$(aws iam list-mfa-devices --user-name {} --query "MFADevices" --output text)" && echo "NO MFA: {}"'

# access keys older than 90 days
aws iam list-users --query 'Users[].UserName' --output text | \
  xargs -n1 -I{} aws iam list-access-keys --user-name {} \
  --query 'AccessKeyMetadata[].{user:UserName,key:AccessKeyId,created:CreateDate}' --output text

# full credential report
aws iam generate-credential-report
aws iam get-credential-report --query Content --output text | base64 -d
```

The credential report is the single best artifact for an access review — one CSV with every
user, key age, MFA status and last use.

## Baseline

- **No root access keys.** Root gets hardware MFA and is then not used.
- **No IAM users** where SSO or federation is possible.
- **MFA** on every human principal.
- **CloudTrail** on, multi-region, to a bucket in a separate account with object lock.
- **SCPs** denying the obviously wrong: disabling CloudTrail, leaving approved regions,
  deleting audit buckets.
- **Permission boundaries** on roles that other people can create roles with.
- **Access Analyzer** enabled, findings reviewed.
- **Access keys rotated** or, better, eliminated.

## Related

- [aws-fundamentals.md](aws-fundamentals.md)
- [eks.md](eks.md) — IRSA
- [../../Secrets Management/secrets-management-patterns.md](../../Secrets%20Management/secrets-management-patterns.md) — OIDC federation
