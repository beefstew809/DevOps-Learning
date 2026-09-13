# Kubernetes Core Objects

https://kubernetes.io/docs/concepts/

The mental model that makes the rest make sense: **you declare desired state, a
controller makes reality match.** You never tell Kubernetes to start a container. You
record that you want three replicas, and a controller notices the gap and closes it.

Everything below is that same loop at different levels.

## The reconciliation loop

```
you:        kubectl apply  ->  desired state stored in etcd
controller: watches        ->  sees actual != desired
controller: acts           ->  creates/deletes to converge
```

Two consequences worth internalising early:

- **Deleting a pod does not remove it.** If a Deployment owns it, the controller makes
  another. To actually stop something you change or delete the *owner*.
- **An error at apply time is not the whole story.** `kubectl apply` validates the
  object and returns. Whether it ever *works* is a separate, asynchronous question,
  which is why `kubectl get` and `describe` matter more here than in most systems.

## Object hierarchy for a typical app

```
Deployment          what you write: image, replicas, update strategy
  └── ReplicaSet    created per revision; handles "keep N pods alive"
        └── Pod     the actual scheduled unit, one or more containers
```

You edit the Deployment. The ReplicaSets exist so rollbacks have something to roll
back to — each image change makes a new one and scales the old to zero.

```bash
kubectl get deploy,rs,pods -l app=web
```

Seeing two ReplicaSets where one has `DESIRED 0` is normal — that is the previous
revision, kept for rollback.

## Pods

The smallest schedulable unit. One or more containers sharing a network namespace and
optionally volumes — so containers in a pod reach each other on `localhost`.

You rarely write a bare Pod. When you do, nothing restarts it; that is the whole
difference between a Pod and a Deployment.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: debug
spec:
  containers:
    - name: shell
      image: docker.io/library/alpine:3.21
      command: ["sleep", "3600"]
```

### Multi-container patterns

| Pattern | Purpose |
| --- | --- |
| **Sidecar** | Helper alongside the app — log shipper, proxy, cert refresher |
| **Init container** | Runs to completion *before* app containers; migrations, waiting on a dependency |
| **Ambassador** | Proxy that makes an external service look local |

Init containers run in order and must each exit 0. A pod stuck in `Init:0/2` means the
first init container has not finished — look at *its* logs, not the app's:

```bash
kubectl logs <pod> -c <init-container-name>
```

## Workload controllers

| Kind | Use for | Key property |
| --- | --- | --- |
| **Deployment** | Stateless apps | Pods are interchangeable; rolling updates |
| **StatefulSet** | Databases, anything with identity | Stable names (`db-0`), stable storage, ordered rollout |
| **DaemonSet** | One pod per node | Log agents, CNI, node exporters |
| **Job** | Run once to completion | Retries via `backoffLimit` |
| **CronJob** | Scheduled Job | Creates Jobs on a cron schedule |

The StatefulSet distinction matters more than it first appears. A Deployment's pods get
random names and share nothing; scaling down may kill any of them. A StatefulSet gives
`db-0`, `db-1` with each keeping its own PersistentVolume across restarts, and scales
down highest-ordinal-first. If a workload cares which instance it is, it needs a
StatefulSet.

### Deployment example, annotated

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web            # MUST match template labels below
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0    # never drop below 3 ready
      maxSurge: 1          # add at most 1 extra during rollout
  template:
    metadata:
      labels:
        app: web           # what the selector matches
    spec:
      containers:
        - name: web
          image: docker.io/library/nginx:1.27
          ports:
            - containerPort: 8080
          resources:
            requests:      # used for scheduling
              cpu: 100m
              memory: 128Mi
            limits:        # enforced ceiling
              cpu: "1"
              memory: 256Mi
```

`selector` is **immutable** after creation. Getting it wrong means deleting and
recreating the Deployment, so it is worth a second look.

## Resource requests and limits

This is where most real clusters go wrong, so it is worth being precise:

- **requests** — what the scheduler reserves. A node needs this much free to accept the
  pod. Too high and pods go `Pending` on a cluster with capacity to spare.
- **limits** — the hard ceiling.

The two behave **completely differently** when exceeded:

| Resource | Over the limit |
| --- | --- |
| **Memory** | Container is **killed** — `OOMKilled`, exit code 137 |
| **CPU** | Container is **throttled**, not killed — it just gets slower |

So a CPU limit that is too low produces a mysteriously slow app with no error
anywhere. Check throttling directly:

```bash
kubectl exec <pod> -- cat /sys/fs/cgroup/cpu.stat | grep throttled
```

A pod with requests but no limits can starve its neighbours. A pod with limits but no
requests gets scheduled onto nodes that cannot really support it. Set both.

Quality of Service class follows from what you set, and decides eviction order when a
node runs out:

| Class | Condition | Evicted |
| --- | --- | --- |
| `Guaranteed` | requests == limits, for all containers | last |
| `Burstable` | requests set, limits higher or absent | middle |
| `BestEffort` | neither set | first |

```bash
kubectl get pod <pod> -o jsonpath='{.status.qosClass}'
```

## Probes

Three kinds, and conflating them causes outages:

```yaml
startupProbe:      # "has it finished booting?" — disables the others until it passes
  httpGet: { path: /healthz, port: 8080 }
  failureThreshold: 30
  periodSeconds: 2

readinessProbe:    # "should it receive traffic?" — failing removes it from Service endpoints
  httpGet: { path: /ready, port: 8080 }
  periodSeconds: 5

livenessProbe:     # "should it be restarted?" — failing KILLS the container
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 10
  failureThreshold: 3
```

The classic failure: a liveness probe that checks a **dependency** (the database) so
when the database blips, every replica is killed simultaneously and the app cannot
recover. Liveness should answer only "is this process wedged?". Dependency health
belongs in readiness.

A slow-starting app with no `startupProbe` gets killed by liveness before it ever
becomes ready, producing a permanent crash loop that looks like a crash bug.

## Configuration: ConfigMaps and Secrets

```bash
kubectl create configmap app-config --from-literal=LOG_LEVEL=debug
kubectl create configmap app-config --from-file=./config.yaml
kubectl create secret generic db-creds --from-literal=password=s3cret
```

Consume as env vars or files:

```yaml
envFrom:
  - configMapRef: { name: app-config }
  - secretRef: { name: db-creds }
volumes:
  - name: config
    configMap: { name: app-config }
```

**Kubernetes Secrets are base64, not encrypted.** Anyone with `get secret` in the
namespace, or read access to etcd, has the plaintext:

```bash
kubectl get secret db-creds -o jsonpath='{.data.password}' | base64 -d
```

Encryption at rest is a separate cluster-level setting (`EncryptionConfiguration`), and
does nothing about RBAC. This is why external secret management exists — see the Vault
and secrets-management notes.

### Mounted config updates, env vars do not

A ConfigMap mounted as a volume is updated in place (within a minute or so). The same
ConfigMap consumed via `envFrom` is read **once at container start** and never changes.
So editing a ConfigMap appears to do nothing for env-var consumers until pods restart:

```bash
kubectl rollout restart deployment/web
```

## Namespaces

Soft boundaries for names, RBAC and quotas. Not a security boundary by themselves —
pods in different namespaces can still reach each other on the network unless a
NetworkPolicy says otherwise.

```bash
kubectl get ns
kubectl -n kube-system get pods
kubectl config set-context --current --namespace=myapp   # stop typing -n
```

Some objects are cluster-scoped (Nodes, PersistentVolumes, ClusterRoles,
StorageClasses) and have no namespace. `kubectl api-resources --namespaced=false`
lists them.

## Labels and selectors

Labels are how everything finds everything. Services select pods by label; Deployments
own pods by label.

```bash
kubectl get pods -l app=web,tier!=canary
kubectl get pods -l 'env in (staging,prod)'
kubectl label pod <pod> canary=true      # hot-remove from a Service by changing labels
```

That last trick is a genuinely useful debugging move: relabel a misbehaving pod so its
Service stops sending it traffic, while leaving it running for inspection. The
Deployment will start a replacement.

Annotations are the same shape but not selectable — they are for tooling metadata.

## Rollouts

```bash
kubectl rollout status deployment/web          # blocks until complete or stuck
kubectl rollout history deployment/web
kubectl rollout undo deployment/web
kubectl rollout undo deployment/web --to-revision=3
kubectl rollout restart deployment/web         # re-create pods, no spec change
```

`rollout status` that never returns means the new pods are not becoming ready — the
readiness probe is failing, the image will not pull, or there is no capacity. With
`maxUnavailable: 0` the old pods stay up, so **the app keeps working while the rollout
is stuck**, which is good for users and easy to miss.

## Reading the object you actually have

The single most useful habit:

```bash
kubectl get deploy web -o yaml                 # everything, including defaults applied
kubectl describe pod <pod>                     # events at the bottom — read these first
kubectl get events --sort-by=.lastTimestamp    # cluster-wide, chronological
kubectl explain deployment.spec.strategy       # schema, without the browser
```

`kubectl explain` is underused and answers "what fields can go here" offline.

## Why a pod is not running

| Status | Meaning | First check |
| --- | --- | --- |
| `Pending` | Not scheduled | `describe pod` events — insufficient resources, no matching node, unbound PVC |
| `ContainerCreating` | Scheduled, starting | Image pull, volume mount |
| `ImagePullBackOff` | Cannot fetch image | Name, tag, registry auth |
| `CrashLoopBackOff` | Starts then exits | `logs --previous` |
| `OOMKilled` | Exceeded memory limit | Raise limit or fix the leak |
| `Error` | Exited non-zero | `logs` |
| `Terminating` (stuck) | Finalizer or ungraceful shutdown | `describe`, check finalizers |

```bash
kubectl logs <pod> --previous    # the run that just died, not the current one
```

`--previous` is the flag to remember for a CrashLoopBackOff: the current container may
not have logged anything yet.

See [kubernetes-troubleshooting.md](kubernetes-troubleshooting.md) for the longer form.

## Related

- [kubernetes-networking.md](kubernetes-networking.md) — Services, Ingress, DNS
- [kubernetes-storage.md](kubernetes-storage.md) — PV, PVC, StorageClass
- [kubernetes-rbac-and-security.md](kubernetes-rbac-and-security.md) — RBAC, contexts, policies
- [../k3s/k3s-Basics.md](../k3s/k3s-Basics.md) — getting a cluster to practise on
