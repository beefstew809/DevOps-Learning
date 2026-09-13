# Vault with Kubernetes

https://developer.hashicorp.com/vault/docs/platform/k8s

The problem: a pod needs a secret, and it has no credential to authenticate with. Giving
it a Vault token to get secrets just moves the secret one step back.

The answer is that **Kubernetes already issues every pod a verifiable identity** — its
ServiceAccount token. Vault can validate that token against the cluster's API server and
issue a Vault token in exchange. No bootstrap secret exists anywhere.

```
pod starts ──► has SA token (kubelet-projected)
            ──► sends it to Vault's kubernetes auth
                    Vault asks the API server "is this token real, and whose is it?"
            ◄── Vault token with policies bound to that ServiceAccount
            ──► read secrets
```

## Configure Kubernetes auth

Vault needs to be able to call the cluster's TokenReview API.

```bash
vault auth enable kubernetes

vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
```

When Vault runs **inside** the cluster that is all it needs — it uses its own SA token and
the injected CA. When Vault is **outside** the cluster you must supply them:

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://k8s.example.internal:6443" \
  kubernetes_ca_cert=@ca.crt \
  token_reviewer_jwt=@reviewer-token
```

The reviewer ServiceAccount needs the `system:auth-delegator` ClusterRole — that is what
permits TokenReview calls:

```bash
kubectl create serviceaccount vault-reviewer -n vault
kubectl create clusterrolebinding vault-reviewer \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault-reviewer
```

Then bind a Vault role to specific ServiceAccounts and namespaces:

```bash
vault write auth/kubernetes/role/myapp \
  bound_service_account_names=myapp \
  bound_service_account_namespaces=production \
  policies=myapp \
  ttl=1h
```

**Both bounds matter.** `bound_service_account_namespaces=*` with a common name like
`default` means any pod in any namespace can assume that role — which is every workload in
the cluster. Name the namespace explicitly.

Test it from inside a pod:

```bash
kubectl exec -it <pod> -- sh -c '
  vault write auth/kubernetes/login \
    role=myapp \
    jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)'
```

## Four ways to get the secret into the pod

| Approach | Secret lands as | Creates a K8s Secret? | Best for |
| --- | --- | --- | --- |
| **Agent Injector** | File in the pod | No | Most apps; templating, renewal |
| **CSI provider** | Mounted volume | No | Apps that read files, strict no-Secret policy |
| **External Secrets Operator** | Kubernetes Secret | **Yes** | Existing charts expecting `secretRef` |
| **App calls Vault directly** | In memory | No | Apps that can handle auth and renewal |

The Secret-vs-no-Secret distinction is the one that matters. ESO is by far the easiest to
adopt because everything already consumes Kubernetes Secrets — but it writes the plaintext
into etcd, so anyone with `get secret` in that namespace can read it. The injector and CSI
keep it out of the API entirely.

## Agent Injector

A mutating webhook that adds a `vault-agent` init container and sidecar based on
annotations. The app reads a file; it never knows Vault exists.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault -n vault --create-namespace \
  --set "injector.enabled=true" --set "server.enabled=false" \
  --set "injector.externalVaultAddr=https://vault.example.internal:8200"
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "myapp"
        vault.hashicorp.com/agent-inject-secret-db: "database/creds/readonly"
        vault.hashicorp.com/agent-inject-template-db: |
          {{- with secret "database/creds/readonly" -}}
          export DB_USER="{{ .Data.username }}"
          export DB_PASS="{{ .Data.password }}"
          {{- end }}
        vault.hashicorp.com/agent-inject-status: "update"   # keep renewing
    spec:
      serviceAccountName: myapp      # must match bound_service_account_names
```

The rendered file appears at `/vault/secrets/db`. Without a template you get raw JSON,
which is rarely what the app wants.

Notes:

- Annotations are read **at pod creation** — the webhook mutates the pod. Adding them to a
  running Deployment requires new pods.
- `agent-inject-status: "update"` keeps the sidecar renewing. Without it the agent runs
  once as an init container and the credential eventually expires.
- The app must **re-read the file** when it changes, or be restarted. Use
  `vault.hashicorp.com/agent-inject-command` to signal it.
- If pods start but `/vault/secrets/` is empty, the injector did not fire: check the
  webhook exists, the namespace is not excluded, and `kubectl logs <pod> -c vault-agent-init`.

## CSI provider

Mounts secrets as a volume through the Secrets Store CSI driver. No Kubernetes Secret, and
the mount is per-pod:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: myapp-db
spec:
  provider: vault
  parameters:
    vaultAddress: "https://vault.example.internal:8200"
    roleName: "myapp"
    objects: |
      - objectName: "db-password"
        secretPath: "secret/data/myapp/db"
        secretKey: "password"
```

```yaml
volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: "myapp-db"
```

Requires the CSI driver installed separately. Rotation support depends on the driver's
rotation-reconciler being enabled; by default the mount is populated at pod start.

## External Secrets Operator

Most pragmatic when charts expect `secretRef`. Two objects: a `SecretStore` describing how
to reach Vault, and an `ExternalSecret` describing what to sync.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault
  namespace: production
spec:
  provider:
    vault:
      server: "https://vault.example.internal:8200"
      path: "secret"
      version: v2
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "myapp"
          serviceAccountRef:
            name: myapp
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-creds
  namespace: production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: SecretStore
  target:
    name: db-creds              # the Kubernetes Secret it creates
    creationPolicy: Owner
  data:
    - secretKey: password        # key in the K8s Secret
      remoteRef:
        key: myapp/db            # path in Vault (no /data/ — ESO handles v2)
        property: password
```

This is the GitOps-friendly option: the `ExternalSecret` is safe to commit because it
contains only a reference. The actual value never appears in git.

Two things to know:

- `path: "secret"` and `version: v2` together handle the KV v2 `/data/` insertion, so
  `remoteRef.key` omits it. Including `data/` yourself gives a confusing 404.
- `creationPolicy: Owner` means deleting the ExternalSecret deletes the Secret. Use
  `Merge` if something else owns it.
- The synced Secret is a normal Kubernetes Secret — base64, readable via RBAC. That is the
  trade for the convenience.

```bash
kubectl get externalsecret -A
kubectl describe externalsecret db-creds      # SecretSynced condition, or the error
```

## Dynamic credentials and pod lifecycle

Dynamic database credentials plus Kubernetes is where the design needs thought. A 1-hour
credential and a pod that reads config once at startup means the app breaks after an hour,
in a way that looks like a database outage.

Options, in order of preference:

1. **App re-reads credentials on connection failure.** Correct, needs app support.
2. **Agent renders the file and signals the app** (`agent-inject-command`) to reload.
3. **Connection pooler** (pgbouncer) holds the long-lived credential; apps talk to it.
4. **Longer TTLs.** Pragmatic, reduces the benefit.

Do not solve it by setting `max_ttl` to a year — that is a static secret with extra steps.

## Running Vault in the cluster

Viable and common, with one caveat worth stating plainly: **Vault in the cluster it secures
is a circular dependency.** A cluster-wide outage means no Vault to recover with, and
Vault's storage lives on the storage you are trying to restore.

If you do it:

```bash
helm install vault hashicorp/vault -n vault --create-namespace \
  --set "server.ha.enabled=true" --set "server.ha.raft.enabled=true"
```

- Three or five replicas with Raft, on a StorageClass with `reclaimPolicy: Retain`.
- Auto-unseal via cloud KMS, or pods stay sealed after every restart and a node reboot
  becomes an outage.
- Raft snapshots off-cluster, with unseal shares stored separately — see
  [vault-basics.md](vault-basics.md).
- `IPC_LOCK` capability for `mlock`, or `disable_mlock=true` with swap off.

For a homelab learning cluster, Vault outside the cluster (or on a separate host) avoids
the circularity and makes the auth configuration more instructive, since you have to set
`kubernetes_host` and the reviewer JWT explicitly.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `permission denied` on login | Role's `bound_service_account_names`/`_namespaces` do not match the pod's SA |
| `invalid audience` / token rejected | Projected token audience mismatch; check `audience` on the Vault role |
| `service account name not authorized` | Pod uses `default` SA, role expects another |
| `/vault/secrets/` empty | Injector webhook did not fire — namespace excluded, or annotations added without recreating pods |
| `403` reading a KV v2 path | Policy missing the `/data/` segment — `secret/data/myapp/*` |
| ESO `SecretSyncedError` 404 | `data/` included in `remoteRef.key` when the store already handles v2 |
| Works then fails after an hour | Lease expired and nothing renewed it |
| Vault pods `0/1 Running` after restart | Sealed. Unseal, or configure auto-unseal |

```bash
kubectl logs <pod> -c vault-agent-init
kubectl logs <pod> -c vault-agent
kubectl -n vault logs statefulset/vault
kubectl -n vault exec vault-0 -- vault status
```

## Related

- [vault-basics.md](vault-basics.md) — policies, engines, seal/unseal, leases
- [secrets-management-patterns.md](secrets-management-patterns.md) — when Vault is overkill
- [../Container Orchestration/kubernetes/kubernetes-rbac-and-security.md](../Container%20Orchestration/kubernetes/kubernetes-rbac-and-security.md) — ServiceAccount tokens
- [../GitOps/gitops-principles.md](../GitOps/gitops-principles.md) — why committed references beat committed secrets
