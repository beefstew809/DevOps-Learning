# GitOps Principles

https://opengitops.dev/

GitOps is one idea applied strictly: **the desired state of the system lives in git, and
an automated process continuously makes reality match it.** Nobody deploys by running a
command against the cluster.

The four principles, from the OpenGitOps project:

1. **Declarative** — the whole system is described as data, not as scripts.
2. **Versioned and immutable** — that description lives in version control, with history.
3. **Pulled automatically** — agents pull the desired state rather than being pushed to.
4. **Continuously reconciled** — agents detect and correct drift, forever.

Kubernetes already works this way internally (see the reconciliation loop in
[../Container Orchestration/kubernetes/kubernetes-core-objects.md](../Container%20Orchestration/kubernetes/kubernetes-core-objects.md)).
GitOps extends the same loop so that git, not etcd, is the source of truth.

## What it actually buys you

Not "deploys via git" — that is the mechanism, not the benefit.

| Property | Why it follows |
| --- | --- |
| **Auditability** | Every change is a commit with an author, timestamp and review. `git log` is the deploy log. |
| **Rollback** | `git revert` is the rollback. No special tooling, same path as any change. |
| **Drift correction** | A hand-edited resource is reverted automatically; the cluster cannot quietly diverge. |
| **Disaster recovery** | Rebuilding a cluster is pointing the agent at the repo. |
| **Least privilege** | Humans need git access, not cluster credentials. CI needs neither. |

That last one is the underrated benefit. In push-based CD, your pipeline holds
cluster-admin credentials and is reachable from the internet. In pull-based GitOps, the
agent runs *inside* the cluster and reaches out to git — so no external system holds
cluster credentials at all.

## Push vs pull

```
PUSH (traditional CI/CD)
  commit -> CI runs tests -> CI runs `kubectl apply` -> cluster
  CI needs cluster credentials. Drift is invisible. No record of actual state.

PULL (GitOps)
  commit -> git                  CI only builds and tests
               ↑
          agent in cluster polls/webhooks, diffs, applies, repeats
  Cluster credentials never leave the cluster. Drift is detected and reported.
```

The practical split: **CI builds artifacts, GitOps deploys them.** CI's job ends at
pushing an image and opening a commit that updates a tag. It never touches the cluster.

## Repository layout

The first real decision. Three common shapes:

### Separate app and config repos (most common)

```
myapp/                  application source, Dockerfile, CI that builds images
myapp-config/           manifests, Helm values, per-environment overlays
```

Keeps deploy history separate from code history, and lets the config repo have different
reviewers. The cost is coordinating two repos for one logical change.

### Monorepo with environment directories

```
infrastructure/
├── base/                       shared manifests
├── environments/
│   ├── dev/
│   ├── staging/
│   └── prod/
└── clusters/
    ├── k3s-home/
    └── eks-prod/
```

Easier to see everything; needs path-scoped agents so a dev change does not sync to prod.

### Branch per environment

```
main     -> prod
staging  -> staging
dev      -> dev
```

**Generally a mistake.** Promotion becomes a merge, merges drift, and hotfixes to prod
have to be back-merged. Directories express environments better than branches, because you
can diff two environments side by side.

## Promotion between environments

The part GitOps does not solve for you. What works:

```
dev:      image tag updated automatically on every build
staging:  promoted by a commit that copies dev's tag
prod:     promoted by a PR, reviewed, merged
```

The artifact is identical across environments — only the manifest reference changes. If
staging builds a different image than prod, you have not tested prod.

Use **digests, not tags**, in the environments that matter:

```yaml
image: registry.example.com/myapp@sha256:9f2c...
```

A tag is a mutable pointer. `myapp:1.4.2` can be re-pushed; `@sha256:...` cannot. Digest
pinning is what makes "the cluster matches git" literally true.

## Secrets: the problem GitOps creates

Everything in git, except credentials must not be in git. Four real answers:

| Approach | How it works | Trade-off |
| --- | --- | --- |
| **SOPS** (+ age/KMS) | Encrypted values committed; agent decrypts | Simple, works offline; key management is yours |
| **Sealed Secrets** | Controller's public key encrypts; only it can decrypt | Easy; ciphertext is cluster-specific |
| **External Secrets Operator** | CRD references a real secret manager; operator syncs into a Secret | Best separation; needs a secret manager |
| **Vault Agent / CSI** | Injected at pod start, never a Kubernetes Secret | Strongest; most moving parts |

The rule: **never commit a plaintext secret, and never work around it by applying secrets
by hand.** A hand-applied Secret is undocumented state that disaster recovery will miss —
the cluster rebuilds and the app cannot start, with nothing in git explaining why.

See [../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md).

## Drift

Drift is any difference between git and the cluster. Agents report it and, if configured,
correct it.

Two ways to handle a hand-made change:

- **Self-heal on** — reverted within minutes. Correct for prod. Note this means
  `kubectl edit` during an incident gets undone, which surprises people at the worst
  moment; use a commit, or suspend the app deliberately.
- **Self-heal off** — drift is reported, a human decides. Reasonable for dev.

Some drift is legitimate and must be excluded, or the agent fights the cluster forever:

- HorizontalPodAutoscaler changing `replicas`
- Webhook controllers injecting sidecars or CA bundles
- `metadata.annotations` written by other controllers

Every GitOps tool has an ignore mechanism for this. Failing to configure it produces an
app permanently `OutOfSync` that nobody trusts any more — which defeats the purpose.

## What does not belong in GitOps

Being honest about the boundaries:

- **Stateful data.** Git holds the PVC definition, not the data. Backups are a separate
  system; see [../Backups/backup-strategy.md](../Backups/backup-strategy.md).
- **Cluster bootstrap.** Something must create the cluster and install the agent.
  Terraform or a script does that; GitOps takes over afterwards.
- **One-off operations.** Database migrations, data backfills, incident surgery. Hooks and
  Jobs help, but imperative work exists and pretending otherwise leads to elaborate
  workarounds.
- **Secrets themselves**, as above — only references to them.

## Getting there from here

Incremental adoption works; big-bang does not.

1. Put existing manifests in git, even imperfect ones. Export with
   `kubectl get -o yaml` and strip the runtime fields (`status`, `resourceVersion`,
   `uid`, `creationTimestamp`, default `nodePort`s).
2. Install an agent pointed at that repo with **self-heal and prune off**. It reports
   drift and changes nothing. This phase is information, not risk.
3. Fix the drift it reports, in git.
4. Turn on self-heal for one low-stakes namespace.
5. Turn on prune last — it is the one that can delete things you wanted.
6. Remove humans' write access to the cluster once the above is trusted.

Step 5 deserves the caution: `prune` deletes cluster resources absent from git. Enable it
only once you are confident everything that should exist is committed.

## Tools

| Tool | Shape |
| --- | --- |
| **ArgoCD** | Application CRD, strong UI, app-of-apps. Easiest to see what is happening. |
| **Flux** | Set of controllers, CLI-first, no default UI. Composes well, lighter footprint. |
| **Rancher Fleet** | Multi-cluster first, bundles. |

ArgoCD and Flux both satisfy the principles. ArgoCD's UI makes drift and sync state
legible, which matters while learning; Flux's controller model fits automation better. See
[argocd.md](argocd.md).

## Related

- [argocd.md](argocd.md)
- [../Container Orchestration/helm/helm-basics.md](../Container%20Orchestration/helm/helm-basics.md)
- [../CI-CD/forgejo/forgejo-actions.md](../CI-CD/forgejo/forgejo-actions.md) — the CI half
- [../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md)
