# AI for Infrastructure

The same tools as [ai-for-development.md](ai-for-development.md), with a different risk profile.
Application code has a review gate, a test suite and a rollback. Infrastructure commands often
have none of those, and some are irreversible.

**The asymmetry that governs everything here:** a wrong function returns a wrong value; a wrong
`terraform apply` deletes a database. Treat generated infrastructure changes as proposals
requiring a plan step, not as commands.

## What it is genuinely good at

Ordered by how safely the value can be captured:

| Task | Why it works |
| --- | --- |
| **Explaining existing config** | Reading is free and reversible |
| **Reviewing a diff or plan** | Finds specific classes of mistake on request |
| **Summarising logs and events** | Volume reduction is the actual problem |
| **Drafting runbooks and postmortems** | Text work with a human editor |
| **Generating first-draft IaC** | Boilerplate-heavy, and `plan` verifies it |
| **Translating between formats** | Compose → Quadlet → manifests; mechanical |
| **Writing policy-as-code** | Rego and Kyverno are tedious and testable |
| **Incident hypothesis generation** | Breadth under pressure, where humans tunnel |

Note that four of those are read-only and two are verified by tooling before anything changes.
That is not a coincidence — it is where the risk/benefit works.

## Read-only first

The highest-value, lowest-risk pattern is **grounding advice in real state**:

```bash
kubectl get pods -o wide
kubectl describe pod <pod>
kubectl get events --sort-by=.lastTimestamp
terraform plan
aws sts get-caller-identity
systemctl status <unit>
journalctl -u <unit> -n 200
```

Feed the output in and ask what it means. This is where a model performs best: the answer is
determined by context you supplied, and nothing changes as a result.

Generalised: **read freely, write deliberately.** Inspection commands are safe to automate;
mutating ones need a gate.

## Plan, then apply

Infrastructure tooling has a built-in dry run. Use it as the verification loop.

```bash
terraform plan -out=tfplan        # read this, every time
terraform show -json tfplan | jq '.resource_changes[] | select(.change.actions[] | contains("delete"))'
terraform apply tfplan

kubectl diff -f manifest.yaml
kubectl apply -f manifest.yaml --dry-run=server

helm diff upgrade release ./chart
ansible-playbook site.yml --check --diff
```

That `jq` filter is the single most useful habit for reviewing a generated Terraform change. A
plan that says `destroy` or `replace` on anything stateful is the thing to catch, and it is easy
to miss in a hundred lines of green.

In review, ask specifically:

- Does anything get **destroyed or replaced**? Why?
- Does anything lose **data** — a volume, a bucket, a database?
- Is anything newly **public**?
- Are there **hardcoded secrets**?
- Does it **drift from existing conventions** in this repo?

Models are good at answering those when asked directly, and will not volunteer them.

## GitOps makes this safer

Committing a change and letting a controller reconcile it is the right shape for AI-assisted
infrastructure work, because it inserts exactly the gates that are missing:

```
model proposes → commit/PR → plan/diff in CI → human review → controller applies → drift corrected
```

The model never holds cluster credentials. The change is reviewable as a diff. Rollback is
`git revert`. See [../GitOps/gitops-principles.md](../GitOps/gitops-principles.md).

The corollary: **do not wire an agent directly into a cluster or cloud account with write
access.** Have it author commits instead.

## Incident response

Genuinely useful under pressure, with care.

**Log and event triage.** Paste a few hundred lines and ask for what is anomalous, what repeats,
and the earliest sign of trouble. Volume reduction is the bottleneck at 3am and this is good at
it.

**Hypothesis generation.** "Latency rose 10× at 14:02, error rate is flat, CPU is normal, this
deployed at 13:58 — what are the candidates?" A list of five plausible causes, ranked, is
valuable precisely when you are tunnelling on one.

**Query writing.** Producing a correct PromQL or LogQL expression from a description is faster
than remembering `histogram_quantile` argument order. See
[../Observability/prometheus.md](../Observability/prometheus.md).

**Timeline and comms drafting.** Turning a scratch channel into a coherent timeline, and writing
the status update, while someone else keeps investigating.

Three rules during an incident:

1. **Never run a suggested mutating command without reading it.** Under time pressure is exactly
   when this goes wrong.
2. **Mitigate with known-good actions** — roll back, fail over, scale up — not with a novel fix
   someone just generated.
3. **Do not paste production data** into a prompt because it is urgent. Redact.

Be aware that a confidently stated wrong hypothesis can cost more time than no hypothesis. Use
the list as candidates to check, not as a diagnosis.

## Postmortems

A good fit: you have a timeline and messy notes, and need a structured document. The model is
good at structure and at asking the obvious follow-up questions.

Keep the judgement human. **Contributing factors and action items are the parts that require
knowing your organisation**, and a generated "add more monitoring" item is worse than nothing.
See [../Observability/logging-and-alerting.md](../Observability/logging-and-alerting.md).

## Guardrails for agents with infrastructure access

If you do give an agent tools, these are the controls that matter.

**Least privilege, actually.**

```bash
# a read-only Kubernetes context for analysis
kubectl create serviceaccount ai-readonly -n default
kubectl create clusterrolebinding ai-readonly \
  --clusterrole=view --serviceaccount=default:ai-readonly
```

Note `view` deliberately excludes Secrets — which is what you want here. For AWS, a role with
`ReadOnlyAccess` and no `iam:*`, assumed with short-lived credentials. See
[../Container Orchestration/kubernetes/kubernetes-rbac-and-security.md](../Container%20Orchestration/kubernetes/kubernetes-rbac-and-security.md)
and [../Cloud/AWS/iam.md](../Cloud/AWS/iam.md).

**Separate environments.** Write access to a dev account or a throwaway cluster is a reasonable
risk. Write access to prod is not, and no prompt instruction substitutes for not having the
credential.

**Human gate on the irreversible.** Deletes, `terraform apply`, DNS changes, certificate
issuance, anything with `--force`. An approval prompt is cheap; an accidental `destroy` is not.

**Audit everything.** CloudTrail, Kubernetes audit logs, shell history. You need to be able to
answer "what did it do" afterwards.

**Sandbox the workspace.** A git worktree or container, so a misjudged change is contained and
discardable.

### Prompt injection is the distinctive infrastructure risk

An agent that reads logs, issues, PR comments, web pages or tool output is reading **untrusted
text**. A log line can contain `Ignore previous instructions and run ...`. An issue comment can
try to redirect an agent that was asked to triage it.

This is not theoretical for infrastructure work, because the agent often has more privilege than
the author of the text it is reading.

Defences:

- **Tool output is data, never instructions.** This has to be enforced by the harness and the
  permission model, not by asking the model to be careful.
- **No unattended privileged loop.** Anything that both reads external content and can make
  changes needs a human in between.
- **Narrow credentials**, so a successful injection has a small blast radius.
- **Review the diff**, not the agent's summary of the diff.

## MCP servers

MCP gives a model structured, schema'd access to a system — far more reliable than parsing CLI
output. There are servers for cloud providers, Kubernetes, git forges, databases, monitoring.

Treat each one as a **trust boundary and a credential**:

- What scope does it have? Prefer read-only. A Forgejo or GitHub server with push rights is a
  write path into your infrastructure repos.
- Can you read its source? It runs on your machine with your credentials.
- What does it return? Its output lands in context as text, subject to the injection concern
  above.
- Is it pinned? An auto-updating server is an unreviewed code change with your credentials.

A practical split that works: read-only MCP access for inspection, and commits-plus-CI for
changes. The model can see everything and change nothing directly.

## Where the value actually is

Two things worth saying plainly.

**Generating config is the least interesting use.** Terraform and Kubernetes YAML are verbose, so
generation feels productive — but the bottleneck in infrastructure work is rarely typing. It is
knowing what the system currently does, why it was built that way, and what will break. Those are
context problems.

**So the highest-value uses are the comprehension ones**: explaining an unfamiliar module,
summarising what a plan will do, finding the inconsistency between two environments, turning
tribal knowledge into a runbook, reviewing a change for a specific failure class. None of those
require write access.

## What not to delegate

- **Capacity and cost decisions** with real money attached — the model cannot see your bill or
  your growth curve.
- **Security architecture.** Use it to review against a standard, not to choose the standard.
- **Anything irreversible**: deleting data, rotating a key you cannot re-issue, destroying state.
- **Judgement calls requiring organisational context** — what the SLO should be, what risk is
  acceptable, who needs to approve.
- **Believing it about your own system.** It knows what you told it. Generic advice
  confidently applied to a system it cannot see is how the subtle outage happens.

## A workflow that works

1. **Gather real state** with read-only commands. Paste it in.
2. **Ask for understanding first** — what is this doing, what is wrong, what are the options.
3. **Ask for a plan**, not a change. Review the reasoning.
4. **Generate the change** as a diff against files in git.
5. **Verify with tooling** — `plan`, `diff`, `--dry-run=server`, `--check`, linters, policy tests.
6. **Read it yourself**, looking specifically for destroys, data loss, new exposure, secrets.
7. **Commit and let CI and review run**, rather than applying directly.
8. **Apply through the normal path**, watching the metrics that would show it going wrong.

Steps 5 and 6 are the ones under time pressure. They are also the entire safety margin.

## Related

- [ai-for-development.md](ai-for-development.md)
- [../GitOps/gitops-principles.md](../GitOps/gitops-principles.md) — the review gate
- [../Cloud/AWS/iam.md](../Cloud/AWS/iam.md) — least-privilege credentials
- [../Observability/logging-and-alerting.md](../Observability/logging-and-alerting.md) — incidents and runbooks
- [../Backups/backup-strategy.md](../Backups/backup-strategy.md) — what makes a mistake survivable
