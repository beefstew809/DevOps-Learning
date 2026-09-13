# Helm

https://helm.sh/docs/

Kubernetes YAML is static; real deployments differ per environment. Helm is a templating
engine plus a release manager: a **chart** is a parameterised bundle of manifests, and
installing one creates a tracked **release** you can upgrade and roll back.

Helm 3 has no server-side component. State lives in Secrets in the release's namespace,
so `helm` is a client talking to the API server with your kubeconfig.

## Chart layout

```
mychart/
├── Chart.yaml          name, version, appVersion, dependencies
├── values.yaml         DEFAULT values — the chart's public interface
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── _helpers.tpl    named templates, by convention underscore-prefixed
│   └── NOTES.txt       printed after install
└── charts/             vendored dependencies
```

Two versions in `Chart.yaml` that are routinely confused:

```yaml
apiVersion: v2
name: mychart
version: 1.4.2        # the CHART's version — bump on any chart change
appVersion: "2.7.0"   # the APP's version — usually the default image tag
```

Changing the image tag default is a chart change, so it bumps **both**.

## The commands

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo postgres
helm show values bitnami/postgresql            # every knob, with defaults

helm install mydb bitnami/postgresql -n data --create-namespace
helm upgrade mydb bitnami/postgresql -f prod-values.yaml
helm upgrade --install mydb bitnami/postgresql -f prod-values.yaml   # idempotent
helm list -A
helm status mydb
helm uninstall mydb
```

`helm upgrade --install` is what belongs in CI — it works whether or not the release
exists, so the pipeline needs no branching.

`helm show values <chart>` before installing anything third-party. It is the chart's
documentation, and usually more accurate than the README.

## Seeing what it will do

The habit that prevents most Helm surprises:

```bash
helm template myrel ./mychart -f prod-values.yaml        # render locally, no cluster
helm install myrel ./mychart --dry-run --debug           # render + server validation
helm diff upgrade myrel ./mychart -f prod-values.yaml    # needs helm-diff plugin
```

`helm template` is offline string substitution. `--dry-run` also validates against the API
server, catching schema and admission problems. **`helm diff upgrade` is the one worth
installing a plugin for** — it shows what changes against the live release, which is the
actual question before an upgrade:

```bash
helm plugin install https://github.com/databus23/helm-diff
```

## Values precedence

Later wins:

```
chart's values.yaml  <  parent chart's values  <  -f file (left to right)  <  --set
```

```bash
helm upgrade web ./mychart \
  -f base.yaml -f prod.yaml \
  --set image.tag=1.2.3 \
  --set-string replicaCount=3 \
  --set-file config=./app.conf
```

- `--set` parses types, so `--set tag=1.10` becomes the float `1.1`. Use `--set-string`
  for anything version-shaped.
- `--set` with commas needs escaping: `--set 'args={a,b}'` is a list; a literal comma is
  `\,`.
- Prefer `-f` files in git over long `--set` chains — the file is reviewable and the
  command is not.

To see what a release was actually installed with:

```bash
helm get values myrel              # user-supplied only
helm get values myrel --all        # merged with chart defaults
helm get manifest myrel            # the YAML currently applied
```

`helm get values myrel` after an incident answers "what was this deployed with", which
nothing else does.

## Templating

Go templates plus Sprig functions.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "mychart.fullname" . }}
  labels:
    {{- include "mychart.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

Built-in objects: `.Values`, `.Chart`, `.Release` (`.Name`, `.Namespace`, `.IsUpgrade`),
`.Capabilities` (cluster version, available API versions), `.Files`.

### Whitespace is the hard part

```
{{- ... }}   trim preceding whitespace INCLUDING the newline
{{ ... -}}   trim following whitespace
```

`nindent N` emits a newline then indents by N — which is why `toYaml . | nindent 12`
appears everywhere. `indent` without the newline is almost always wrong after a `:`.

When rendering breaks, look at the actual output rather than reasoning about the template:

```bash
helm template ./mychart --show-only templates/deployment.yaml
```

### Conditionals and emptiness

```yaml
{{- if .Values.ingress.enabled }}
{{- if and .Values.tls.enabled (not .Values.tls.existingSecret) }}
{{- if .Values.persistence }}      # careful: 0, "", false and empty map are all falsy
```

`{{ if .Values.replicaCount }}` is false when `replicaCount` is `0`. Use
`{{ if not (kindIs "invalid" .Values.replicaCount) }}` or `hasKey` when zero is a
meaningful value.

`required` and `fail` turn silent misconfiguration into a clear error:

```yaml
password: {{ required "database.password is required" .Values.database.password | b64enc }}
```

That is worth using on anything that would otherwise deploy broken.

### Validate values with a schema

`values.schema.json` next to `values.yaml` is checked on install, lint and template:

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["image"],
  "properties": {
    "replicaCount": { "type": "integer", "minimum": 1 },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": { "repository": { "type": "string" } }
    }
  }
}
```

This catches a typo in a values file before it becomes a broken rollout, and is the single
best addition to a chart other people use.

## Dependencies

```yaml
# Chart.yaml
dependencies:
  - name: postgresql
    version: "16.x.x"
    repository: https://charts.bitnami.com/bitnami
    condition: postgresql.enabled        # skip it if false
```

```bash
helm dependency update ./mychart     # writes Chart.lock, populates charts/
helm dependency build ./mychart      # install exactly what Chart.lock pins
```

Commit `Chart.lock`. Whether to commit `charts/` is a real choice: vendoring makes builds
reproducible offline, at the cost of a large diff on every bump.

Override a subchart's values by nesting under its name, and use `global` for values both
need:

```yaml
postgresql:
  auth:
    database: myapp
global:
  imageRegistry: registry.example.com
```

## Upgrades, rollback, and history

```bash
helm history myrel
helm rollback myrel          # previous revision
helm rollback myrel 3
```

Each revision is stored as a Secret (`sh.helm.release.v1.<name>.v<n>`), capped by
`--history-max` (default 10).

```bash
helm upgrade myrel ./mychart --atomic --timeout 5m
```

`--atomic` rolls back automatically if the upgrade fails, which is what you want in CI.
It implies `--wait`, so it blocks until resources are ready — meaning the timeout must
exceed a realistic rollout.

### Releases stuck `pending-upgrade`

An interrupted `helm upgrade` (cancelled CI job, timeout, lost connection) leaves the
release in `pending-upgrade`, and every later command refuses with *"another operation is
in progress"*. Nothing is actually running.

```bash
helm history myrel              # confirm the top revision is pending-*
helm rollback myrel <last-good-revision>
```

In Helm 3.12+, `helm upgrade --install` does this for you with:

```bash
helm upgrade --install myrel ./mychart --force-replace-on-conflict 2>/dev/null || true
```

but the reliable fix remains an explicit rollback to the last deployed revision.

## Hooks

```yaml
metadata:
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

Hooks run at `pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`,
`pre-delete`, `post-delete`, and `test`. The usual case is a database migration Job.

**Hooks are not part of the release's managed resources**, so they are not rolled back and
a failed hook blocks the upgrade. Set a `hook-delete-policy` or failed hook Jobs accumulate
and block the next run with an "already exists" error.

`helm.sh/resource-policy: keep` on a PVC stops `helm uninstall` from deleting it — worth
setting on anything holding data, since the default takes the volume with the release.

## Testing and linting

```bash
helm lint ./mychart
helm lint ./mychart -f prod-values.yaml       # lint the values you actually use
helm template ./mychart | kubectl apply --dry-run=server -f -
helm test myrel                               # runs hook: test resources
```

In CI, `helm template` piped into `kubeconform` or `kubectl --dry-run=server` catches
schema errors before they reach a cluster. `chart-testing` (`ct lint`) is the fuller tool
for chart repos.

## OCI registries

Charts are OCI artifacts now; plain HTTP chart repos are legacy:

```bash
helm package ./mychart
helm push mychart-1.4.2.tgz oci://registry.example.com/charts
helm install myrel oci://registry.example.com/charts/mychart --version 1.4.2
```

Same registry as images, same auth, same signing path (cosign). If you run a registry
already, prefer this over hosting an index.

## Helm and GitOps

Helm's imperative `upgrade` conflicts with GitOps' "the cluster matches git". The usual
resolutions:

- **ArgoCD renders the chart** and applies the output, so ArgoCD owns state and Helm is
  only a template engine. No Helm release Secrets exist. This is the common choice.
- **Argo/Flux drives `helm` itself** (Flux's HelmRelease), keeping Helm's release history
  and hooks.

Either is fine; mixing a human running `helm upgrade` with a controller syncing the same
namespace is not — they fight. See [../../GitOps/argocd.md](../../GitOps/argocd.md).

## When not to use Helm

Templating YAML with string substitution has real costs: whitespace bugs, unreadable
templates, and values files that become their own configuration language. Alternatives
worth knowing:

- **Kustomize** — patches plain YAML instead of templating it. Built into `kubectl -k`.
  Better when you have one app and a few environment overlays.
- **Plain manifests** — for a handful of objects you control, templating earns nothing.

Helm's advantage is distribution: it is how third parties ship applications, so you will
consume charts regardless of what you author.

## Related

- [../kubernetes/kubernetes-core-objects.md](../kubernetes/kubernetes-core-objects.md)
- [../../GitOps/argocd.md](../../GitOps/argocd.md)
- [../../GitOps/gitops-principles.md](../../GitOps/gitops-principles.md)
