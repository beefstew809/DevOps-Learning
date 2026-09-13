# Kubernetes RBAC and Security

https://kubernetes.io/docs/reference/access-authn-authz/rbac/

Every request to the API server goes through three gates in order:

```
Authentication  ->  Authorization (RBAC)  ->  Admission control
"who are you?"      "may you do that?"        "is the object acceptable?"
```

Failing the first gives `Unauthorized`. Failing the second gives `Forbidden` with the
exact verb and resource, which makes RBAC errors unusually easy to diagnose — the error
message tells you what rule to write.

## Two kinds of identity

**ServiceAccounts** are Kubernetes objects, for workloads in the cluster:

```bash
kubectl create serviceaccount deployer
kubectl get sa
```

**Users and groups are not Kubernetes objects.** There is no `kubectl create user`. The
API server learns identity from whatever authenticator is configured — a client
certificate's CN, an OIDC token's claims, a cloud IAM mapping. RBAC then references that
string. This surprises people: you can grant permissions to `jane@example.com` with no
object named `jane` existing anywhere.

## The four RBAC objects

|  | Namespaced | Cluster-scoped |
| --- | --- | --- |
| **Permissions** | `Role` | `ClusterRole` |
| **Grant** | `RoleBinding` | `ClusterRoleBinding` |

A Role lists what may be done. A binding attaches it to a subject. Both halves are
required — a Role alone grants nothing.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: myapp
  name: pod-reader
rules:
  - apiGroups: [""]                      # "" is the core group
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: myapp
  name: read-pods
subjects:
  - kind: ServiceAccount
    name: deployer
    namespace: myapp
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### The combination people miss

A **RoleBinding can reference a ClusterRole**. That grants the ClusterRole's permissions
*only within the binding's namespace* — which is how you reuse one definition across
many namespaces without granting cluster-wide access:

```yaml
kind: RoleBinding
metadata:
  namespace: myapp
roleRef:
  kind: ClusterRole          # cluster-scoped definition
  name: edit                 # built in
```

That is the right tool for "this team admins their own namespace". Using a
ClusterRoleBinding instead grants it everywhere — an easy and serious mistake.

### Finding verbs and resource names

```bash
kubectl api-resources                    # names, short names, api groups, namespaced?
kubectl api-resources --api-group=apps
```

Subresources are separate strings: `pods/log`, `pods/exec`, `deployments/scale`. Granting
`pods` does **not** grant `pods/log`, which is why a working dashboard can still fail to
show logs.

`pods/exec` is effectively root on anything that pod can reach — treat granting it as
granting shell access, not as a read permission.

## Built-in ClusterRoles

| Name | Grants |
| --- | --- |
| `view` | Read most things, **excluding Secrets** |
| `edit` | Write most things; cannot change RBAC |
| `admin` | `edit` plus RBAC within a namespace |
| `cluster-admin` | Everything, everywhere |

Start from `view`/`edit` rather than writing Roles from scratch. Note `view` deliberately
excludes Secrets — a "read-only" grant that includes Secrets is not read-only in any
meaningful sense.

## Testing permissions instead of guessing

`auth can-i` is the most useful RBAC command and answers authoritatively:

```bash
kubectl auth can-i create deployments -n myapp
kubectl auth can-i delete nodes

# as someone else — the important form
kubectl auth can-i list secrets -n myapp \
  --as=system:serviceaccount:myapp:deployer

# everything a subject can do
kubectl auth can-i --list --as=system:serviceaccount:myapp:deployer
```

The ServiceAccount username format is `system:serviceaccount:<namespace>:<name>`. Use
`--as` to verify a grant before shipping it, and again after an incident to see what an
identity actually had.

```bash
kubectl auth whoami          # who the current kubeconfig says you are
```

## ServiceAccount tokens in pods

Every pod gets a ServiceAccount — `default` if unspecified — and its token is mounted at
`/var/run/secrets/kubernetes.io/serviceaccount/token`. The `default` account has almost
no permissions, but the token still identifies the pod to the API server, so it is
credential material worth not handing out:

```yaml
spec:
  serviceAccountName: myapp
  automountServiceAccountToken: false     # for anything that never calls the API
```

Turning the mount off for workloads that do not need the API is cheap and removes a step
from most container-escape chains.

Modern tokens are short-lived and projected, rotated by the kubelet. The old pattern of a
long-lived Secret per ServiceAccount is deprecated; do not create those by hand.

## Pod-level security

### securityContext

The defaults are permissive. A hardened pod spec:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

Each line earns its place:

- `runAsNonRoot` — fails the pod outright if the image would run as UID 0, rather than
  silently running privileged.
- `readOnlyRootFilesystem` — the highest-value single setting, and the one that surfaces
  hidden assumptions. Anything needing to write gets an explicit `emptyDir`.
- `drop: ["ALL"]` — then add back only what is needed (`NET_BIND_SERVICE` for ports
  below 1024).
- `seccompProfile: RuntimeDefault` — blocks the syscalls nothing legitimately needs.

`privileged: true` disables essentially all of this. It is occasionally required (CNI,
storage drivers) and otherwise a red flag.

### Pod Security Admission

PodSecurityPolicy was removed in 1.25. Its replacement is built in and applied with
namespace **labels**:

```bash
kubectl label namespace myapp \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

Three levels: `privileged` (no restrictions), `baseline` (blocks known escalations),
`restricted` (enforces the hardening above). Three modes: `enforce` rejects,
`audit` logs, `warn` returns a warning to the client.

The migration path that works: set `warn` and `audit` first, watch what would break, then
turn on `enforce`. Going straight to `enforce=restricted` on an existing namespace
usually blocks the next deploy.

For policy beyond this — registry allow-lists, required labels, custom rules — use
Kyverno or Gatekeeper.

## Kubeconfig and contexts

```bash
kubectl config get-contexts
kubectl config current-context
kubectl config use-context prod
kubectl config set-context --current --namespace=myapp
```

Three pieces: a **cluster** (API endpoint + CA), a **user** (credentials), and a
**context** binding them with a default namespace.

`KUBECONFIG` accepts a colon-separated list, which merges files:

```bash
export KUBECONFIG=~/.kube/config:~/.kube/k3s.yaml
kubectl config view --flatten > ~/.kube/merged
```

**The operational risk here is running the right command against the wrong cluster.**
`kubectl delete` does not ask. Mitigations that work: never make prod the default
context, put the context in your shell prompt (`kube-ps1`, starship), and use `--context`
explicitly in anything scripted.

Kubeconfig files are credentials in plaintext. `chmod 600`, never commit them. The
`k3s.yaml` on a k3s server is root-owned for that reason.

## Cluster-level concerns

**etcd holds everything, including Secrets, unencrypted by default.** Encryption at rest
is a separate API-server `EncryptionConfiguration`, and backups of etcd are as sensitive
as the cluster itself.

**Audit logging** is off by default in most distributions. It is the only record of who
did what, and worth enabling before you need it.

**API server exposure** — `kubectl` from the internet means the API is reachable from the
internet. Prefer a private endpoint plus a VPN or tailnet.

## Supply chain

RBAC does not help if the image is hostile. Briefly, and covered properly in the
security notes:

- Pin by digest, not tag, so what you reviewed is what runs.
- Scan images in CI (`trivy`, `grype`) and fail on fixable criticals.
- Generate an SBOM so you can answer "are we affected" without rebuilding.
- Use a private registry with the cluster pulling via a dedicated credential.

## Quick audit

```bash
# who has cluster-admin
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") |
         "\(.metadata.name): \([.subjects[]?.name] | join(", "))"'

# pods running as root
kubectl get pods -A -o json | jq -r '
  .items[] | select((.spec.securityContext.runAsNonRoot // false) == false) |
  "\(.metadata.namespace)/\(.metadata.name)"'

# privileged pods
kubectl get pods -A -o json | jq -r '
  .items[] | select(any(.spec.containers[];
    .securityContext.privileged == true)) |
  "\(.metadata.namespace)/\(.metadata.name)"'

# who can read secrets everywhere
kubectl auth can-i list secrets --all-namespaces --as=system:serviceaccount:default:default
```

## Related

- [kubernetes-core-objects.md](kubernetes-core-objects.md) — Secrets are base64, not encrypted
- [kubernetes-networking.md](kubernetes-networking.md) — NetworkPolicy, the other half of isolation
- [../../Secrets Management/vault-kubernetes.md](../../Secrets%20Management/vault-kubernetes.md) — real secret storage
