# Kubernetes Networking

https://kubernetes.io/docs/concepts/services-networking/

Four rules the cluster network must satisfy, and everything else follows from them:

1. Every pod gets its own IP.
2. Pods can reach each other directly by IP, across nodes, **without NAT**.
3. Nodes can reach pods without NAT.
4. The IP a pod sees for itself is the IP others use to reach it.

That flat model is why there are no port conflicts between pods and why you almost
never publish ports the way Docker does. The component implementing it is the **CNI
plugin** (Calico, Cilium, Flannel, or k3s's default). Kubernetes itself implements none
of this.

## The problem Services solve

Pod IPs are ephemeral. A rollout replaces every IP. So nothing should ever address a
pod directly.

A **Service** is a stable name and virtual IP in front of a set of pods selected by
label. It is not a process — it is rules programmed into each node by `kube-proxy` (or
eBPF, with Cilium).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web            # matches POD labels, not the Deployment's name
  ports:
    - name: http
      port: 80          # the Service's port
      targetPort: 8080  # the container's port
```

`port` vs `targetPort` is the usual mix-up: clients talk to `port`, traffic arrives at
`targetPort`. If `targetPort` is wrong you get connection refused through a Service
that looks perfectly healthy.

### Are there actually any backends?

A Service with no matching pods accepts connections and drops them. The check:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl get endpoints web          # older, still works and is more readable
```

**Empty endpoints is the single most common Service bug**, and it has exactly two
causes: the selector does not match any pod's labels, or the pods are not *ready*
(failing readiness probe). A pod that is `Running` but not `Ready` is deliberately
excluded.

## Service types

| Type | Reachable from | Mechanism |
| --- | --- | --- |
| `ClusterIP` | Inside the cluster only (default) | Virtual IP |
| `NodePort` | `<anyNodeIP>:30000-32767` | Port opened on every node |
| `LoadBalancer` | External IP | Cloud provider provisions an LB |
| `ExternalName` | — | Returns a CNAME; no proxying |
| Headless (`clusterIP: None`) | Inside | DNS returns **pod IPs** directly |

Headless Services are what StatefulSets use. Instead of one virtual IP, DNS returns
every pod IP, and each pod also gets its own name:

```
web-0.web.default.svc.cluster.local
web-1.web.default.svc.cluster.local
```

That is how a database replica addresses a specific peer — which a normal Service
cannot express.

`LoadBalancer` on bare metal does nothing by itself; nothing provisions the LB and the
Service sits in `<pending>` forever. On bare metal you need MetalLB, or k3s's bundled
ServiceLB.

## DNS

CoreDNS resolves Services. The naming scheme:

```
<service>.<namespace>.svc.cluster.local
```

Resolution is relative, so within a namespace `web` is enough; across namespaces you
need `web.other-namespace`. That shortening is set up by the `search` list in every
pod's `/etc/resolv.conf`:

```bash
kubectl exec -it <pod> -- cat /etc/resolv.conf
```

Testing DNS from inside the cluster, which is where you should test it:

```bash
kubectl run -it --rm dnstest --image=docker.io/library/alpine:3.21 --restart=Never -- sh
# then:
nslookup web
nslookup web.default.svc.cluster.local
wget -qO- http://web.default.svc.cluster.local
```

If short names fail but fully-qualified ones work, the problem is `search`/`ndots`, not
CoreDNS. If both fail, check CoreDNS itself:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns
```

## Ingress

A Service of type LoadBalancer per app means one external IP per app. **Ingress** is
HTTP-aware routing that shares one entry point across many Services, by hostname and
path.

An Ingress object is only data. It does nothing without an **ingress controller** —
Traefik (bundled with k3s), ingress-nginx, HAProxy — actually watching Ingress objects
and configuring itself. Creating an Ingress on a cluster with no controller produces no
error and no effect, which is a common first stumble.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  ingressClassName: traefik
  tls:
    - hosts: [app.example.com]
      secretName: web-tls        # cert-manager writes the cert here
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
```

Notes that save time:

- **The Ingress must be in the same namespace as the Service** it references. Cross-
  namespace backends are not supported; you need an Ingress per namespace.
- `pathType: Prefix` vs `Exact` matters. `Prefix` with `/` catches everything.
- The TLS `secretName` must exist in that namespace too. cert-manager creates it, but
  until it succeeds the controller serves its own default certificate — which presents
  as a browser warning rather than an error anywhere in Kubernetes.

```bash
kubectl describe ingress web        # events show the controller's view
kubectl get certificate            # cert-manager's own object, if used
```

## Gateway API

The intended successor to Ingress, now the direction of travel for new work. It splits
the single Ingress object into roles so cluster operators and app teams do not edit the
same file:

| Object | Owned by | Describes |
| --- | --- | --- |
| `GatewayClass` | infra provider | Implementation |
| `Gateway` | cluster operator | Listeners, ports, TLS |
| `HTTPRoute` | app team | Hostnames, paths, backends |

It also handles things Ingress only expressed through implementation-specific
annotations — header-based routing, traffic splitting for canaries, and cross-namespace
references via `ReferenceGrant`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web
spec:
  parentRefs:
    - name: external-gateway
  hostnames: ["app.example.com"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: web-stable
          port: 80
          weight: 90
        - name: web-canary
          port: 80
          weight: 10
```

That weighted split is the clearest illustration of why Gateway API exists: expressing
it with Ingress requires controller-specific annotations that do not port between
controllers.

Ingress is not going away and is still the right choice for simple routing, but new
clusters should expect to grow into Gateway API.

## NetworkPolicy

**By default every pod can talk to every other pod in the cluster**, in any namespace.
Namespaces are not a network boundary. NetworkPolicy is how you change that.

Critically: policies are **allow-lists that only apply to pods they select**. A pod
with no policy selecting it is unrestricted. The moment one policy selects a pod, that
pod is restricted to what policies explicitly allow.

Default-deny ingress for a namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: myapp
spec:
  podSelector: {}        # every pod in the namespace
  policyTypes: [Ingress]
```

Then allow what is needed:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-to-db
  namespace: myapp
spec:
  podSelector:
    matchLabels: { app: db }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { app: web }
      ports:
        - protocol: TCP
          port: 5432
```

Two traps:

- **A default-deny policy blocks DNS**, because DNS is egress to CoreDNS in
  `kube-system`. Deny egress without allowing UDP/TCP 53 and everything breaks in a way
  that looks like a DNS outage. Allow it explicitly.
- **NetworkPolicy requires CNI support.** Flannel does not enforce it. The policies
  apply cleanly, report no error, and do nothing — verify your CNI enforces them before
  relying on policy for isolation.

## Debugging connectivity, in order

Work outward from the pod:

```bash
# 1. Is the pod ready? Not-ready pods are excluded from Services.
kubectl get pods -o wide

# 2. Does the Service have endpoints?
kubectl get endpoints web

# 3. Can you reach the pod IP directly? (rules out the Service)
kubectl exec -it <other-pod> -- wget -qO- http://10.42.0.7:8080

# 4. Can you reach the Service name? (rules out DNS vs routing)
kubectl exec -it <other-pod> -- wget -qO- http://web.default:80

# 5. Bypass everything from your workstation
kubectl port-forward svc/web 8080:80
```

`port-forward` is the fastest way to separate "the app is broken" from "the routing is
broken" — it skips Service load balancing, Ingress and DNS entirely.

For images with no shell, attach a debug container that has one:

```bash
kubectl debug -it <pod> --image=docker.io/nicolaka/netshoot --target=<container>
```

`kubectl debug` shares the target's namespaces, so `netshoot` sees the same network as
the broken container — which is the point, and much better than guessing.

## Related

- [kubernetes-core-objects.md](kubernetes-core-objects.md) — why readiness gates traffic
- [kubernetes-rbac-and-security.md](kubernetes-rbac-and-security.md)
- [../../reverse_proxy/traefik.md](../../reverse_proxy/traefik.md) — the controller k3s ships
- [../../Networking/networking-fundamentals.md](../../Networking/networking-fundamentals.md) — CIDR, NAT, TCP underneath all this
