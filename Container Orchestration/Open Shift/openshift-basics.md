# Open Shift

https://docs.openshift.com/

Red Hat's Kubernetes distribution. It is Kubernetes underneath — `kubectl` works —
plus an opinionated layer on top: an integrated registry, build and deployment
objects, Routes instead of raw Ingress, and security defaults that are stricter
than upstream.

## How it differs from plain Kubernetes

| Concept | Kubernetes | OpenShift |
| --- | --- | --- |
| Namespace | `Namespace` | `Project` (a Namespace plus annotations) |
| External access | `Ingress` + a controller | `Route` (Ingress also works) |
| Build from source | external tooling | `BuildConfig` / Source-to-Image |
| Rollouts | `Deployment` | `Deployment`, or the older `DeploymentConfig` |
| CLI | `kubectl` | `oc` (a superset of kubectl) |

The difference that actually bites first is **security context constraints (SCCs)**.
By default a pod runs as an arbitrary high-numbered UID, not as the UID in the
image. Container images that assume they are root, or that `chown` a mounted path,
fail on OpenShift while working fine on k3s or Docker. That is the single most
common reason an off-the-shelf image does not come up.

## Running one for learning

A full cluster wants substantial resources. Two smaller options:

**OpenShift Local** (formerly CodeReady Containers) — a single-node cluster in a VM
on your workstation. Needs a free Red Hat account for the pull secret.

```bash
crc setup
crc start
eval $(crc oc-env)
oc whoami
```

Budget ~4 CPUs and 16 GB RAM; it is heavier than a k3s node by a wide margin.

**OKD** — the community distribution OpenShift is built from, with no subscription.
https://www.okd.io/

## oc basics

```bash
oc login https://api.mycluster:6443 -u developer
oc new-project scratch
oc get pods
oc project scratch              # switch the active project

oc new-app --image=nginx:alpine  # create a deployment from an image
oc expose deployment/nginx --port=80
oc expose service/nginx          # creates a Route with a generated hostname
oc get route

oc logs -f deployment/nginx
oc rsh deployment/nginx          # shell into a pod
oc describe pod/<name>           # first stop when a pod will not start
```

## When an image will not start

Check the SCC problem before anything else:

```bash
oc get events --sort-by=.lastTimestamp
oc describe pod/<name>
```

Permission-denied on a volume, or a container insisting it must be root, is the
signature. The correct fix is to build an image that tolerates an arbitrary UID —
make the paths it writes to group-writable and owned by group `0`. Granting the
`anyuid` SCC makes it start but throws away the protection, so treat that as a
diagnostic, not a fix.

## Notes

- `oc` can talk to any Kubernetes cluster, not just OpenShift.
- For a homelab, k3s is the cheaper way to learn Kubernetes itself. OpenShift is
  worth the trouble when the goal is the Red Hat platform specifically — SCCs,
  Routes, BuildConfigs, and the operator model — because those are what differ in
  practice. See [../k3s/k3s-Basics.md](../k3s/k3s-Basics.md).
