# ArgoCD

https://argo-cd.readthedocs.io/

A controller that runs in the cluster, watches git repositories, and makes the cluster
match them. Its core object is the **Application**: a pairing of "this path in this repo"
with "this namespace in this cluster".

## Install and first login

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

The initial admin password is generated into a Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  — admin / <that password>
```

Delete that Secret once you have set a real password or wired SSO; it is a static
credential sitting in the namespace otherwise.

The CLI is worth installing — it does things the UI does not:

```bash
argocd login localhost:8080
argocd app list
```

## The Application object

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd              # Applications live in argocd, not the target namespace
spec:
  project: default
  source:
    repoURL: https://git.example.com/homelab/myapp-config.git
    targetRevision: main
    path: environments/prod
  destination:
    server: https://kubernetes.default.svc    # this cluster
    namespace: myapp
  syncPolicy:
    automated:
      prune: true                # delete resources removed from git
      selfHeal: true             # revert manual changes
    syncOptions:
      - CreateNamespace=true
```

The three fields that decide behaviour:

- **`prune`** — deletes cluster resources no longer in git. Off by default, and the one to
  enable last. With it off, deleting a file leaves the resource running forever.
- **`selfHeal`** — reverts drift. With it off, drift is reported but not corrected.
- **`targetRevision`** — a branch tracks continuously; a tag or commit SHA pins. Prod
  pinned to a tag gives you an explicit promotion step.

### Sync states you will see

| Status | Meaning |
| --- | --- |
| `Synced` / `Healthy` | Cluster matches git, resources report healthy |
| `OutOfSync` | Git and cluster differ — expected right after a commit, or drift |
| `Synced` / `Progressing` | Applied, waiting for readiness |
| `Synced` / `Degraded` | Applied, but a resource reports unhealthy (failing probe, CrashLoop) |
| `Unknown` | Cannot read the repo — auth, network, bad path |
| `Missing` | In git, not in the cluster yet |

`Synced` + `Degraded` is the important distinction: ArgoCD did its job correctly and the
*application* is broken. Do not debug ArgoCD for that — go to
[../Container Orchestration/kubernetes/kubernetes-troubleshooting.md](../Container%20Orchestration/kubernetes/kubernetes-troubleshooting.md).

```bash
argocd app get myapp
argocd app diff myapp             # git vs live, the most useful command
argocd app sync myapp
argocd app history myapp
argocd app rollback myapp 7
```

`argocd app diff` before a manual sync is the equivalent of `helm diff` or `kubectl diff`.

## Private repositories

Most homelab repos are private. A deploy key is the cleanest:

```bash
ssh-keygen -t ed25519 -f argocd-deploy -C "argocd"
# add argocd-deploy.pub as a read-only deploy key on the repo

argocd repo add git@git.example.com:homelab/myapp-config.git \
  --ssh-private-key-path ./argocd-deploy
```

Or declaratively, which is better since it is itself reviewable:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-config-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository    # REQUIRED, or ArgoCD ignores it
stringData:
  type: git
  url: git@git.example.com:homelab/myapp-config.git
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
```

That label is the whole mechanism — ArgoCD discovers credentials by label, so a Secret
without it is silently unused and the Application sits at `Unknown`.

For a self-hosted git server with its own CA or on a tailnet, add the host key too
(`argocd-ssh-known-hosts-cm` ConfigMap) or connections fail host verification.

## Helm and Kustomize sources

ArgoCD renders both itself; it does not run `helm install`. No Helm release Secrets exist
and `helm list` shows nothing — ArgoCD owns the resources directly.

```yaml
source:
  repoURL: https://charts.bitnami.com/bitnami
  chart: postgresql
  targetRevision: 16.2.1
  helm:
    valueFiles:
      - $values/environments/prod/postgres.yaml
    values: |
      auth:
        database: myapp
    parameters:
      - name: image.tag
        value: "17.2.0"
```

Combining a third-party chart with values from your own repo uses multiple sources:

```yaml
spec:
  sources:
    - repoURL: https://charts.bitnami.com/bitnami
      chart: postgresql
      targetRevision: 16.2.1
      helm:
        valueFiles:
          - $values/environments/prod/postgres.yaml
    - repoURL: https://git.example.com/homelab/myapp-config.git
      targetRevision: main
      ref: values          # the $values reference above
```

Kustomize needs no configuration — a `kustomization.yaml` at `path` is detected:

```yaml
source:
  path: environments/prod
  kustomize:
    images:
      - registry.example.com/myapp:1.4.2
```

## App of apps

Bootstrapping many Applications by committing one. A root Application whose `path`
contains Application manifests:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://git.example.com/homelab/infrastructure.git
    targetRevision: main
    path: apps                     # directory full of Application YAML
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Now adding an app is committing a file. Rebuilding the cluster is installing ArgoCD and
applying `root`.

### Sync waves for ordering

Resources apply in waves, lowest first; each wave waits for the previous to be healthy:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"     # CRDs, namespaces, operators
```

Use this where order genuinely matters — CRDs before the resources using them, a database
before the app. Default is `0`, negatives run first.

## ApplicationSet

Generates Applications from a template, for "the same app across environments or clusters"
without copy-pasted YAML:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: myapp-envs
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
            revision: main
          - env: prod
            revision: v1.4.2
  template:
    metadata:
      name: 'myapp-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://git.example.com/homelab/myapp-config.git
        targetRevision: '{{revision}}'
        path: 'environments/{{env}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'myapp-{{env}}'
```

Other generators: `git` (directory or file discovery — add a directory, get an
Application), `cluster` (fan out to every registered cluster), `matrix` (combine two).

The `git` directory generator plus a convention is how teams let app owners self-serve:
create `environments/newthing/`, get an Application.

## Projects for guardrails

`AppProject` restricts what Applications may do — the mechanism for multi-tenancy:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-a
  namespace: argocd
spec:
  sourceRepos:
    - https://git.example.com/homelab/team-a-*
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'team-a-*'
  clusterResourceWhitelist: []        # no cluster-scoped resources at all
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
```

Without this, any Application in `argocd` can deploy anything anywhere — including
cluster-scoped RBAC. `clusterResourceWhitelist: []` is the important line for untrusted
tenants.

## Ignoring legitimate drift

Without this, an HPA-scaled app is permanently `OutOfSync` and the signal becomes noise:

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas          # HPA owns this
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - '.webhooks[]?.clientConfig.caBundle'
```

Better still for replicas, omit the field from git entirely and let the HPA own it. The
general rule: whoever writes a field at runtime should be the only writer.

## Notifications

ArgoCD does not tell you about failures by default. `argocd-notifications` sends on
triggers like `on-sync-failed`, `on-health-degraded`:

```yaml
# argocd-notifications-cm
trigger.on-health-degraded: |
  - when: app.status.health.status == 'Degraded'
    send: [app-degraded]
template.app-degraded: |
  message: "{{.app.metadata.name}} is degraded"
```

Subscribe per Application with an annotation. Worth setting up early — a GitOps system
nobody is watching is a system that drifts silently when syncs start failing.

## Troubleshooting

```bash
argocd app get myapp                              # per-resource status
argocd app diff myapp                             # what differs
argocd app sync myapp --dry-run
kubectl -n argocd logs deploy/argocd-repo-server   # rendering and git errors
kubectl -n argocd logs deploy/argocd-application-controller
```

| Symptom | Cause |
| --- | --- |
| `Unknown`, "repository not accessible" | Credentials missing, wrong `repoURL`, missing label on the repo Secret, unknown SSH host key |
| `ComparisonError` on a Helm chart | Rendering failed — see `repo-server` logs; reproduce locally with `helm template` |
| Permanently `OutOfSync`, no real diff | Another controller owns a field — add `ignoreDifferences` |
| Sync succeeds, resources missing | `prune` deleted them — they are not in git |
| `OutOfSync` immediately after sync | Mutating webhook or defaulting changes the object post-apply |
| Sync hangs in `Progressing` | A resource never becomes healthy — probes, PVC, image pull |
| `another operation is already in progress` | Previous sync still running; `argocd app terminate-op myapp` |

A resource ArgoCD cannot classify shows `Unknown` health — custom CRDs need a health check
Lua script in `argocd-cm` to report properly. Until then `Progressing` forever is expected
for some operators.

## Operational notes

- **Self-heal fights you during incidents.** A `kubectl edit` to mitigate an outage gets
  reverted in minutes. Either commit the mitigation or
  `argocd app set myapp --sync-policy none` deliberately, and remember to restore it.
- **ArgoCD managing itself** is the usual pattern and works, but an Application that
  breaks ArgoCD leaves nothing to fix it with. Keep the install manifests applyable by
  hand.
- **Deleting an Application deletes its resources** when prune/cascade is on. To remove
  the Application only: `argocd app delete myapp --cascade=false`.
- **Back up ArgoCD's state** or accept rebuilding it from git — which is the point, so
  ensure the root Application and repo credentials are themselves recoverable.

## Related

- [gitops-principles.md](gitops-principles.md) — the why, and repo layout
- [../Container Orchestration/helm/helm-basics.md](../Container%20Orchestration/helm/helm-basics.md)
- [../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md) — what to do about credentials
