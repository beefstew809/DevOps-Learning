# Amazon EKS

https://docs.aws.amazon.com/eks/latest/userguide/

Managed Kubernetes: AWS runs the control plane, you run the workloads. What makes EKS
distinctive is not Kubernetes — it is the two integration points where AWS concepts meet
Kubernetes concepts, and both are where people get stuck:

1. **Identity** — mapping IAM to Kubernetes RBAC.
2. **Networking** — pods get real VPC IP addresses.

Everything in [../../Container Orchestration/kubernetes/](../../Container%20Orchestration/kubernetes/)
applies unchanged. This note is only the AWS-specific part.

## What AWS manages, and what it does not

| AWS runs | You run |
| --- | --- |
| API server, etcd, scheduler, controller-manager | Nodes (unless Fargate/Auto Mode) |
| Control-plane HA across 3 AZs | Add-ons, upgrades, workloads |
| Control-plane backups | **Your data, your backups** |

The control plane costs ~$73/month per cluster regardless of size, which makes
cluster-per-environment a real cost decision for small setups. Nodes are ordinary EC2
instances at ordinary EC2 prices.

## Creating a cluster

`eksctl` is the fastest path for learning; Terraform for anything lasting.

```yaml
# cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: learning
  region: us-east-1
  version: "1.31"
iam:
  withOIDC: true                # REQUIRED for IRSA — do this from the start
managedNodeGroups:
  - name: default
    instanceType: m7g.large     # Graviton, ~20% cheaper
    amiFamily: AmazonLinux2023
    desiredCapacity: 2
    minSize: 1
    maxSize: 4
    privateNetworking: true
    volumeType: gp3
addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
```

```bash
eksctl create cluster -f cluster.yaml
aws eks update-kubeconfig --name learning --region us-east-1
kubectl get nodes
```

`withOIDC: true` matters — without the OIDC provider, IRSA does not work and retrofitting it
means touching every service account. Turn it on at creation.

## Identity: IAM to Kubernetes RBAC

Two directions, often confused:

- **Inbound** — an IAM principal needs Kubernetes permissions to use `kubectl`.
- **Outbound** — a pod needs IAM permissions to call AWS APIs.

### Inbound: access entries

The old mechanism was the `aws-auth` ConfigMap, where a YAML typo locked everyone out. The
current mechanism is **access entries**, which are a real API:

```bash
aws eks create-access-entry --cluster-name learning \
  --principal-arn arn:aws:iam::123456789012:role/Developers \
  --type STANDARD

aws eks associate-access-policy --cluster-name learning \
  --principal-arn arn:aws:iam::123456789012:role/Developers \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy \
  --access-scope type=namespace,namespaces=dev
```

Use access entries on any new cluster. `aws-auth` still works but is legacy.

**The cluster creator has implicit admin that appears in no policy.** A cluster created by a
CI role is administrable by that role, and possibly by nobody else — which strands teams whose
bootstrap role was temporary. Add explicit access entries for the humans and roles that need
it, immediately after creation.

```bash
aws eks list-access-entries --cluster-name learning
kubectl auth whoami
```

### Outbound: IRSA and Pod Identity

**IRSA** (IAM Roles for Service Accounts) uses the cluster's OIDC provider: the pod's
ServiceAccount token is exchanged for IAM credentials. Same idea as Vault's Kubernetes auth.

```bash
eksctl create iamserviceaccount \
  --cluster learning --namespace myapp --name s3-reader \
  --attach-policy-arn arn:aws:iam::123456789012:policy/ReadAppBucket \
  --approve
```

That annotates the ServiceAccount:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader
  namespace: myapp
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/eksctl-...-s3-reader
```

The role's trust policy ties it to that exact namespace and ServiceAccount:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABC123" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/ABC123:sub": "system:serviceaccount:myapp:s3-reader",
      "oidc.eks.us-east-1.amazonaws.com/id/ABC123:aud": "sts.amazonaws.com"
    }
  }
}
```

**Scope that `sub` condition.** A wildcard there lets any pod in the cluster assume the role.

**EKS Pod Identity** is the newer, simpler alternative — an addon plus an association, no OIDC
trust policy to write and it works across clusters:

```bash
aws eks create-pod-identity-association --cluster-name learning \
  --namespace myapp --service-account s3-reader \
  --role-arn arn:aws:iam::123456789012:role/app-s3-reader
```

Prefer Pod Identity for new work; IRSA remains necessary where a tool only supports it.

Either way, **the pod must use that ServiceAccount** (`serviceAccountName:`). Without it the
pod falls back to the node's instance profile — which usually has broader permissions, so the
call *succeeds* and you never notice the pod is over-privileged. That silent fallback is the
thing to watch for: restrict the node role so it cannot mask mistakes.

## Networking: the VPC CNI and IP exhaustion

**Every pod gets a real VPC IP from the subnet.** No overlay. That means direct security-group
reachability and no encapsulation overhead — and it means **pods consume subnet addresses**.

Each instance type supports a fixed number of ENIs, each with a fixed number of IPs:

```
max pods ≈ (ENIs × (IPs per ENI − 1)) + 2
m5.large  → 3 ENIs × 10 = 29 pods
t3.medium → 3 ENIs × 6  = 17 pods
```

```bash
kubectl get node <node> -o jsonpath='{.status.allocatable.pods}'
```

Two failures follow:

- **Pods `Pending` with `too many pods`** — the node hit its ENI-derived limit while having
  plenty of CPU and memory. Bigger instances, or enable prefix delegation.
- **`failed to assign an IP address to container`** — the *subnet* is out of addresses. This
  takes the whole cluster down for scheduling and cannot be fixed by adding nodes.

Mitigations:

```bash
# prefix delegation: assign /28 prefixes instead of single IPs — many more pods per node
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true
```

And size subnets generously from the start — `/20` per private subnet, not `/24`. See
[vpc-and-networking.md](vpc-and-networking.md).

```bash
aws ec2 describe-subnets --subnet-ids subnet-abc \
  --query 'Subnets[].AvailableIpAddressCount'
```

Custom networking can put pods in a secondary CIDR (`100.64.0.0/16`) to keep them off your
routable space entirely — worth knowing when the VPC is already tight.

## Load balancers and ingress

The **AWS Load Balancer Controller** turns Kubernetes objects into real AWS load balancers:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=learning \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
    alb.ingress.kubernetes.io/group.name: shared    # share ONE ALB across Ingresses
spec:
  ingressClassName: alb
```

- `target-type: ip` sends traffic straight to pod IPs, skipping the extra `kube-proxy` hop.
  Possible because pods have VPC IPs.
- **`group.name` is the cost lever.** Without it, every Ingress creates its own ALB at ~$16/month
  each. Grouping shares one.
- **Subnets must be tagged** or the controller cannot discover them:
  `kubernetes.io/role/elb=1` for public, `kubernetes.io/role/internal-elb=1` for private.
  Missing tags produce an Ingress that never gets an address, with the reason only in the
  controller's logs.

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller
```

## Storage

```bash
aws eks create-addon --cluster-name learning --addon-name aws-ebs-csi-driver
```

The driver needs IRSA/Pod Identity with `AmazonEBSCSIDriverPolicy`, or volumes never
provision.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
```

`WaitForFirstConsumer` is **not optional on EKS**: EBS volumes are AZ-bound, so binding before
scheduling produces a volume in one AZ and a pod that cannot be placed there. This is the
most common EKS storage failure.

EFS via the EFS CSI driver is the option when you need `ReadWriteMany`.

## Scaling nodes

| Option | Notes |
| --- | --- |
| **Karpenter** | Provisions right-sized nodes directly from pending pods. Faster, cheaper, now the recommended choice |
| **Cluster Autoscaler** | Scales existing node groups. Simpler, constrained by group shapes |
| **Fargate** | No nodes at all; per-pod billing, no DaemonSets, no privileged pods |
| **EKS Auto Mode** | AWS manages nodes and core addons entirely |

Karpenter is the meaningful improvement: it looks at what pods need and launches an instance
that fits, including Spot, rather than scaling a fixed template.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64", "amd64"]
      nodeClassRef:
        name: default
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
```

`consolidationPolicy` actively bin-packs and terminates underused nodes — real savings, and a
behaviour to understand before enabling, since it moves running pods. PodDisruptionBudgets are
what keep that safe.

## Upgrades

EKS supports roughly the latest four minor versions, with each supported about 14 months.
Standard support ending moves you to paid extended support automatically — a silent cost
increase.

Order matters:

```bash
# 1. check for deprecated APIs FIRST
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
pluto detect-all-in-cluster

# 2. control plane (one minor version at a time, never skip)
eksctl upgrade cluster --name learning --version 1.32 --approve

# 3. addons
aws eks update-addon --cluster-name learning --addon-name vpc-cni --addon-version v1.19.0-eksbuild.1

# 4. nodes last
eksctl upgrade nodegroup --cluster learning --name default --kubernetes-version 1.32
```

Nodes may be at most one minor version *behind* the control plane and never ahead — hence the
order. You cannot skip minor versions, and you cannot downgrade.

## Cost notes specific to EKS

- **~$73/month per cluster** for the control plane. Namespaces are cheaper than clusters for
  separating environments in a small setup.
- **One ALB per Ingress** unless grouped — see `group.name` above.
- **NAT Gateway per-GB** charges on every image pull. VPC endpoints for ECR and S3 pay for
  themselves quickly.
- **Cross-AZ pod-to-pod traffic** is charged both ways. A service mesh with topology-aware
  routing, or `topologyKeys`, keeps traffic local.
- **Graviton + Spot via Karpenter** is the largest single lever on node cost.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `kubectl` → `You must be logged in to the server` | No access entry / `aws-auth` mapping for your principal |
| Nodes never join | Node role missing policies, no route to the API, or missing subnet tags |
| Pod `Pending`, `too many pods` | ENI IP limit for the instance type |
| `failed to assign an IP address` | Subnet exhausted |
| Pod gets node's IAM permissions | `serviceAccountName` not set — silent fallback |
| PVC `Pending` forever | EBS CSI driver lacks IRSA, or `volumeBindingMode: Immediate` across AZs |
| Ingress has no address | Subnets not tagged for ELB discovery; check controller logs |
| `AccessDenied` from a pod with IRSA | Trust policy `sub` does not match `namespace:serviceaccount` |

```bash
aws eks describe-cluster --name learning --query 'cluster.{status:status,version:version,endpoint:endpoint}'
kubectl -n kube-system logs -l k8s-app=aws-node          # VPC CNI
kubectl -n kube-system get pods
```

## Related

- [../../Container Orchestration/kubernetes/](../../Container%20Orchestration/kubernetes/) — the Kubernetes itself
- [iam.md](iam.md) — OIDC federation, PassRole
- [vpc-and-networking.md](vpc-and-networking.md) — subnet sizing
- [../../GitOps/argocd.md](../../GitOps/argocd.md)
