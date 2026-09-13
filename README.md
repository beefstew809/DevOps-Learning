# DevOps Learning

Notes and working examples for the tooling behind a self-hosted homelab and the cloud-engineering
practices around it — containers, orchestration, configuration management, CI, secrets, networking,
observability and backups.

These are working notes, not a tutorial series. Each page is meant to be useful on the day you come
back to a tool you have not touched in three months: the commands that matter, the layout of the
config, and the specific failures that waste an afternoon.

## Start here

New to this, or picking a path through it:

1. [Linux for DevOps](Fundamentals/linux-for-devops.md) — systemd, cgroups, permissions. Everything else sits on this.
2. [Networking fundamentals](Networking/networking-fundamentals.md) — CIDR, TCP, DNS, TLS.
3. [Docker basics](Containers/docker/docker-basics.md) → [Dockerfile best practices](Containers/docker/dockerfile-best-practices.md)
4. [Kubernetes core objects](Container%20Orchestration/kubernetes/kubernetes-core-objects.md) — after a [k3s](Container%20Orchestration/k3s/k3s-Basics.md) cluster exists to practise on.
5. [Observability fundamentals](Observability/observability-fundamentals.md) — you cannot operate what you cannot see.
6. [Backup strategy](Backups/backup-strategy.md) — before you need it.

## Contents

### Fundamentals
| | |
| --- | --- |
| [linux-for-devops.md](Fundamentals/linux-for-devops.md) | systemd, journald, processes, cgroups, permissions, SELinux, shell hygiene |
| [git-workflows.md](Fundamentals/git-workflows.md) | Branching, rebase vs merge, recovery, bisect, hooks, history rewriting |

### Containers
| | |
| --- | --- |
| [docker-basics.md](Containers/docker/docker-basics.md) | Installing Docker and Compose, with and without Ansible |
| [dockerfile-best-practices.md](Containers/docker/dockerfile-best-practices.md) | Layer caching, multi-stage, non-root, build secrets, multi-arch, scanning |
| [Containers/docker/](Containers/docker) | Working compose stacks: Traefik, Authentik, Homepage, Dozzle, code-server, Filebrowser, Uptime Kuma, drawio |
| [Use-Podman.md](Containers/Podman/Use-Podman.md) | Podman in production, Quadlet as IaC, secrets, logging |
| [Configure-Rootless-Podman.md](Containers/Podman/Configure-Rootless-Podman.md) | Rootless setup end to end, subuid/subgid, verification |
| [quadlets.md](Containers/Podman/quadlets.md) | Containers as systemd units, and the three rules that save time |
| [Multi Container Quadlet.md](Containers/Podman/Multi%20Container%20Quadlet.md) | Pods, unit naming, readiness ordering |
| [buildah.md](Containers/Podman/buildah.md) | Building images without a daemon |

### Container Orchestration
| | |
| --- | --- |
| [kubernetes-core-objects.md](Container%20Orchestration/kubernetes/kubernetes-core-objects.md) | Reconciliation, workloads, requests vs limits, probes, rollouts |
| [kubernetes-networking.md](Container%20Orchestration/kubernetes/kubernetes-networking.md) | Services, endpoints, DNS, Ingress, Gateway API, NetworkPolicy |
| [kubernetes-storage.md](Container%20Orchestration/kubernetes/kubernetes-storage.md) | PV/PVC/StorageClass, access modes, reclaim policies, snapshots |
| [kubernetes-rbac-and-security.md](Container%20Orchestration/kubernetes/kubernetes-rbac-and-security.md) | RBAC, ServiceAccounts, securityContext, Pod Security Admission |
| [kubernetes-troubleshooting.md](Container%20Orchestration/kubernetes/kubernetes-troubleshooting.md) | Triage order, pod states, exit codes, `kubectl debug` |
| [helm-basics.md](Container%20Orchestration/helm/helm-basics.md) | Charts, values precedence, templating, releases, stuck upgrades |
| [k3s-Basics.md](Container%20Orchestration/k3s/k3s-Basics.md) | Single-binary Kubernetes, joining nodes, kubeconfig |
| [openshift-basics.md](Container%20Orchestration/Open%20Shift/openshift-basics.md) | OpenShift vs plain Kubernetes, `oc`, SCCs |

### GitOps
| | |
| --- | --- |
| [gitops-principles.md](GitOps/gitops-principles.md) | Pull vs push, repo layout, promotion, drift, what does not belong |
| [argocd.md](GitOps/argocd.md) | Applications, sync states, app-of-apps, ApplicationSets, projects |

### Infrastructure as Code
| | |
| --- | --- |
| [ansible-basics.md](Infrastructure%20as%20Code/ansible/ansible-basics.md) | Control node setup, inventory, vault |
| [ansible/requirements.yml](Infrastructure%20as%20Code/ansible/requirements.yml) | Galaxy roles and collections, pinned |
| [ansible/roles/](Infrastructure%20as%20Code/ansible/roles) | Local roles, and why Galaxy roles are not vendored |
| [terraform-basics.md](Infrastructure%20as%20Code/terraform/terraform-basics.md) | The plan/apply loop, state, remote backends |
| [build_execution_environment.md](Infrastructure%20as%20Code/AAP/build_execution_environment.md) | Ansible Automation Platform execution environments |

### Cloud — AWS
| | |
| --- | --- |
| [aws-fundamentals.md](Cloud/AWS/aws-fundamentals.md) | Accounts, regions, compute choice, where the money goes |
| [iam.md](Cloud/AWS/iam.md) | Policy evaluation, roles over users, workload identity, reading AccessDenied |
| [vpc-and-networking.md](Cloud/AWS/vpc-and-networking.md) | Subnets, gateways, security groups vs NACLs, load balancers |
| [storage-and-databases.md](Cloud/AWS/storage-and-databases.md) | Object vs block vs file, S3 classes and lifecycle, EBS, RDS, KMS |
| [eks.md](Cloud/AWS/eks.md) | Access entries, IRSA/Pod Identity, VPC CNI IP limits, Karpenter |

### Secrets Management
| | |
| --- | --- |
| [secrets-management-patterns.md](Secrets%20Management/secrets-management-patterns.md) | The hierarchy, OIDC federation, SOPS vs Sealed Secrets, rotation, leak response |
| [vault-basics.md](Secrets%20Management/vault-basics.md) | Auth/policies/engines, seal and unseal, dynamic credentials, leases |
| [vault-kubernetes.md](Secrets%20Management/vault-kubernetes.md) | Kubernetes auth, Agent injector, CSI, External Secrets Operator |

### Observability
| | |
| --- | --- |
| [observability-fundamentals.md](Observability/observability-fundamentals.md) | Metrics/logs/traces, cardinality, golden signals, SLOs, burn rate |
| [prometheus.md](Observability/prometheus.md) | PromQL, recording and alerting rules, Alertmanager, kube-prometheus-stack |
| [logging-and-alerting.md](Observability/logging-and-alerting.md) | Structured logs, Loki, dashboards, runbooks, incidents, blackbox probes |

### Networking
| | |
| --- | --- |
| [networking-fundamentals.md](Networking/networking-fundamentals.md) | Layers, CIDR, TCP, DNS, routing, NAT, MTU, diagnostics |
| [dns-and-tls.md](Networking/dns-and-tls.md) | Zone design, SPF/DKIM/DMARC/CAA, certificate chains, ACME, renewal |

### Reverse proxy
| | |
| --- | --- |
| [traefik.md](reverse_proxy/traefik.md) | Routers, middleware chains, ACME, label-driven routing |
| [nginx.md](reverse_proxy/nginx.md) | Static reverse proxying, TLS, the headers you must set |

### CI/CD
| | |
| --- | --- |
| [forgejo-actions.md](CI-CD/forgejo/forgejo-actions.md) | Forgejo Actions, runner config, where it diverges from GitHub Actions |
| [gitlab-basics.md](CI-CD/gitlab/gitlab-basics.md) | GitLab CI pipelines, runners, variables |
| [CI-CD/github/](CI-CD/github) | GitHub Actions workflow example |
| [CI-CD/Dockerfiles/ansible-linter/](CI-CD/Dockerfiles/ansible-linter) | Linter image used by CI |

### Backups
| | |
| --- | --- |
| [backup-strategy.md](Backups/backup-strategy.md) | RPO/RTO, 3-2-1-1-0, what to back up, verification, runbooks |
| [restic-and-restore-testing.md](Backups/restic-and-restore-testing.md) | restic, retention, automated restore verification |

### Security
| | |
| --- | --- |
| [supply-chain-and-devsecops.md](Security/supply-chain-and-devsecops.md) | Dependencies, scanning that survives, SBOM, signing, pipeline hardening |

### AI
| | |
| --- | --- |
| [ai-for-development.md](AI/ai-for-development.md) | Where it helps, verification, failure modes, cost, security |
| [ai-for-infrastructure.md](AI/ai-for-infrastructure.md) | Read-only first, plan-then-apply, guardrails, prompt injection |

## Conventions

- **Upstream code is declared, not vendored.** Galaxy roles live in `requirements.yml` with a pinned
  version. Only locally written roles are committed.
- **Runtime state is not committed.** Certificates, logs, `.env` files and secrets are gitignored. A
  stack that writes into its own directory needs that path ignored before it is first run.
- **Images are pinned**, and Renovate opens a PR when a pinned version moves.
- **Every note opens with the upstream documentation link.** These notes are a shortcut, not a
  replacement.
- **Verified claims over remembered ones.** Where a note asserts a tool's behaviour, it was checked
  against that tool rather than recalled — version-specific claims say which version.

## Renovate

Dependency updates arrive as pull requests, tracked on the **Dependency Dashboard** issue. Note that
this repo has no status checks configured, so updates gated on "pending status checks" will wait
indefinitely — approve them from the dashboard.
