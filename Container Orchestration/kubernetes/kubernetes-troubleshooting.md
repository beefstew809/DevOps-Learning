# Kubernetes Troubleshooting

The method matters more than the commands. Kubernetes failures are almost always at a
boundary — scheduler/node, pod/image, Service/pod, Ingress/Service — so the fastest route
is to **bisect the path** rather than to read logs hoping for an answer.

## Start here, always

```bash
kubectl describe pod <pod>
```

The **Events** section at the bottom is where Kubernetes explains itself: why the
scheduler refused, why the image would not pull, why the volume would not attach. Reading
logs before `describe` is the most common wasted step — if the container never started,
there are no logs to read.

Events expire (one hour by default), so an empty Events list on an old problem means the
evidence is gone, not that nothing happened.

```bash
kubectl get events --sort-by=.lastTimestamp            # cluster-wide, chronological
kubectl get events --field-selector type=Warning -A
```

## The four-question triage

In order, because each rules out a layer:

```bash
# 1. Is it scheduled?            Pending = scheduler problem
kubectl get pods -o wide

# 2. Did the container start?    ImagePull/CrashLoop = image or app problem
kubectl describe pod <pod>

# 3. Is it Ready?                Running-but-not-Ready = probe problem
kubectl get pod <pod>

# 4. Can traffic reach it?       Ready but unreachable = Service/Ingress problem
kubectl get endpoints <service>
```

`READY 0/1` with `STATUS Running` is the case worth recognising on sight: the container is
up, the readiness probe is failing, and therefore **no Service sends it traffic**. The app
is not crashed; it is excluded.

## Pod states and what they actually mean

### Pending

Never scheduled. `describe` says which constraint could not be met.

| Event text | Cause |
| --- | --- |
| `Insufficient cpu` / `Insufficient memory` | No node has that much **requested** capacity free |
| `node(s) didn't match Pod's node affinity` | Selector/affinity matches nothing |
| `node(s) had untolerated taint` | Needs a toleration |
| `pod has unbound immediate PersistentVolumeClaims` | PVC is Pending |
| `waiting for first consumer` on the PVC | Normal — resolves when scheduled |

The capacity one is a trap: a node can be nearly idle and still reject the pod, because
scheduling is based on the sum of **requests**, not current usage.

```bash
kubectl describe node <node> | grep -A8 'Allocated resources'
kubectl top nodes                 # actual usage, needs metrics-server
```

Compare those two. Requests at 95% with usage at 10% means over-requesting, not a real
capacity problem.

### ImagePullBackOff / ErrImagePull

```bash
kubectl describe pod <pod> | grep -A5 Events
```

| Message | Cause |
| --- | --- |
| `manifest unknown` / `not found` | Tag or name wrong |
| `unauthorized` | Missing or wrong `imagePullSecrets` |
| `no such host` | Registry DNS — often a cluster DNS problem, not a registry one |
| `x509: certificate signed by unknown authority` | Private registry CA not trusted by the node |

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=user --docker-password=token
```

Then reference it in the pod spec, or attach it to the ServiceAccount so every pod in the
namespace inherits it:

```bash
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

### CrashLoopBackOff

The container starts and exits. **This is an application problem, not a Kubernetes one** —
Kubernetes is faithfully restarting something that keeps dying.

```bash
kubectl logs <pod> --previous          # the run that died; current may be empty
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
```

| Exit code | Meaning |
| --- | --- |
| 0 | Exited cleanly — the command finished. A Deployment needs a long-running process. |
| 1 | Application error — read logs |
| 137 | SIGKILL — usually OOMKilled, check `reason` |
| 139 | SIGSEGV |
| 143 | SIGTERM — shut down on request |

The "exit 0" case confuses people: the container did nothing wrong, it just finished. A
`Job` would be satisfied; a `Deployment` restarts it forever.

The backoff is exponential up to five minutes, so a pod that has been crashing a while
appears to hang rather than restart.

To inspect an image whose entrypoint crashes immediately, override it:

```bash
kubectl run debug --rm -it --image=myapp:broken \
  --restart=Never --command -- sh
```

### OOMKilled

```bash
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
```

The container exceeded its memory **limit**. Either the limit is too low or the app leaks.
Check what it actually used before raising blindly:

```bash
kubectl top pod <pod> --containers
```

Note a JVM or Node process that does not know its cgroup limit will size its heap to the
*node's* memory and get killed on any node bigger than the limit. Modern runtimes are
container-aware, older ones need explicit flags.

### Terminating forever

```bash
kubectl get pod <pod> -o jsonpath='{.metadata.finalizers}'
```

Either a finalizer is waiting on something that will never complete, or the node is gone
and the kubelet cannot confirm deletion. `--force --grace-period=0` removes the API object
**without confirming the container stopped** — for a StatefulSet with RWO storage that can
mean two pods believing they own one volume. Understand the node's state first.

## Logs

```bash
kubectl logs <pod>
kubectl logs <pod> -c <container>            # multi-container pods
kubectl logs <pod> --previous                # the crashed run
kubectl logs -f deployment/web               # follows one pod of the set
kubectl logs -l app=web --all-containers --tail=50 --prefix
kubectl logs <pod> --since=15m
```

`--prefix` with a label selector is the one to remember for "which replica is doing this".

For control-plane behaviour, the kubelet is on the node, not in the API:

```bash
journalctl -u kubelet -f          # or -u k3s on a k3s server
```

## Getting inside

```bash
kubectl exec -it <pod> -- sh
kubectl exec <pod> -- env                  # no TTY needed for one-shot
kubectl cp <pod>:/var/log/app.log ./app.log
```

For distroless or scratch images with no shell, `exec` fails. Attach an ephemeral
container that shares the target's namespaces:

```bash
kubectl debug -it <pod> --image=docker.io/nicolaka/netshoot --target=<container>
```

`--target` is what makes it see the same network and processes. Without it you get a
sidecar in the same pod but not the same process namespace.

To debug a node itself:

```bash
kubectl debug node/<node> -it --image=docker.io/library/alpine:3.21
# host filesystem is at /host
```

And to debug a pod whose spec is the problem, copy it with changes:

```bash
kubectl debug <pod> -it --copy-to=debug-pod --container=app -- sh
```

## Network problems

Bisect from the inside out — each step rules out a layer:

```bash
# pod IP directly — rules out Service, DNS, Ingress
kubectl exec <other-pod> -- wget -qO- http://10.42.0.7:8080

# Service name — rules out DNS vs routing
kubectl exec <other-pod> -- wget -qO- http://web.default.svc.cluster.local

# from your workstation, bypassing Ingress entirely
kubectl port-forward svc/web 8080:80
```

If `port-forward` works and the Ingress does not, the app is fine and the problem is
routing. That one comparison resolves a large share of "the site is down" reports.

Endpoints first, always:

```bash
kubectl get endpoints web
```

Empty means the selector matches nothing, or no pod is Ready. See
[kubernetes-networking.md](kubernetes-networking.md).

## Node problems

```bash
kubectl get nodes
kubectl describe node <node>
```

| Condition | Meaning |
| --- | --- |
| `Ready=False` | kubelet not reporting — node down, or network partition |
| `MemoryPressure` | Evicting pods |
| `DiskPressure` | Evicting pods, garbage-collecting images |
| `SchedulingDisabled` | Cordoned |

`NotReady` with pods still listed as Running is a partition, not necessarily a dead node —
the API server has simply stopped hearing from it.

Maintenance:

```bash
kubectl cordon <node>                                   # no new pods
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>
```

`drain` respects PodDisruptionBudgets and will block rather than violate one — which is
the point, and looks like a hang. `kubectl get pdb -A` shows what is holding it.

## Resource and quota

```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory
kubectl get resourcequota -A
kubectl describe resourcequota -n myapp
```

A namespace with a ResourceQuota rejects pods that do not declare requests/limits at all —
the error is at create time and names the missing field.

If `kubectl top` errors, metrics-server is not installed. It is not part of core
Kubernetes.

## API and control plane

```bash
kubectl cluster-info
kubectl get --raw='/readyz?verbose'
kubectl api-versions
kubectl -n kube-system get pods          # control plane, if self-hosted
```

For k3s specifically, the control plane is inside one process:

```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 100 --no-pager
```

## A YAML that will not apply

```bash
kubectl apply -f app.yaml --dry-run=server      # validates against the real API
kubectl apply -f app.yaml --dry-run=client      # schema only, offline
kubectl diff -f app.yaml                        # what would change
kubectl explain deployment.spec.template.spec   # what fields are legal here
```

`--dry-run=server` catches admission-webhook rejections and defaulting that client-side
validation misses. `kubectl diff` before an apply on a live cluster is a good habit.

Common YAML traps, none of which produce an obvious error:

- Tabs. YAML forbids them.
- `selector.matchLabels` not matching `template.metadata.labels` — the Deployment is
  rejected, or worse, owns nothing.
- Quoting: `"true"`, `"1.10"` and `"on"` are strings; unquoted they become bool/float/bool.
  An image tag of `1.10` silently becomes `1.1`.
- Memory units: `1000M` (decimal) vs `1000Mi` (binary) are different numbers.

## A loop that works

1. `kubectl get pods -o wide` — what state, on which node
2. `kubectl describe pod` — **read the Events**
3. `kubectl logs --previous` — if it ran at all
4. Bisect the network path if it is Ready but unreachable
5. `kubectl get events --sort-by=.lastTimestamp` — if the pod looks fine but something else is wrong
6. Check the node and the control plane last

Resist jumping to step 3. Most problems are answered at step 2.

## Related

- [kubernetes-core-objects.md](kubernetes-core-objects.md) — probes, requests vs limits
- [kubernetes-networking.md](kubernetes-networking.md) — endpoints, DNS, Ingress
- [kubernetes-storage.md](kubernetes-storage.md) — Pending PVCs, attach failures
- [../../Observability/observability-fundamentals.md](../../Observability/observability-fundamentals.md) — knowing before a user tells you
