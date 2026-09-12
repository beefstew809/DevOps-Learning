# DevOps Learning

Notes and working examples for the tooling behind a self-hosted homelab — containers,
configuration management, CI, and the proxy in front of it all.

These are working notes, not a tutorial series. Each page is meant to be useful on the
day you come back to a tool you have not touched in three months: the commands that
matter, the layout of the config, and the specific failures that waste an afternoon.

## Contents

### Containers
| | |
| --- | --- |
| [docker-basics.md](Containers/docker/docker-basics.md) | Installing Docker and Compose, with and without Ansible |
| [Containers/docker/](Containers/docker) | Working compose stacks: Traefik, Authentik, Homepage, Dozzle, code-server, Filebrowser, Uptime Kuma, drawio |
| [Use-Podman.md](Containers/Podman/Use-Podman.md) | Podman day to day |
| [Configure-Rootless-Podman.md](Containers/Podman/Configure-Rootless-Podman.md) | Rootless setup end to end |
| [quadlets.md](Containers/Podman/quadlets.md) | Running containers as systemd units |
| [Multi Container Quadlet.md](Containers/Podman/Multi%20Container%20Quadlet.md) | Multi-container quadlets |
| [buildah.md](Containers/Podman/buildah.md) | Building images without a daemon |

### Infrastructure as Code
| | |
| --- | --- |
| [ansible-basics.md](Infrastructure%20as%20Code/ansible/ansible-basics.md) | Control node setup, inventory, vault |
| [ansible/requirements.yml](Infrastructure%20as%20Code/ansible/requirements.yml) | Galaxy roles and collections, pinned |
| [ansible/roles/](Infrastructure%20as%20Code/ansible/roles) | Locally written roles, and why Galaxy roles are not vendored |
| [terraform-basics.md](Infrastructure%20as%20Code/terraform/terraform-basics.md) | The plan/apply loop, state, remote backends |
| [build_execution_environment.md](Infrastructure%20as%20Code/AAP/build_execution_environment.md) | Ansible Automation Platform execution environments |

### CI/CD
| | |
| --- | --- |
| [forgejo-actions.md](CI-CD/forgejo/forgejo-actions.md) | Forgejo Actions, runner config, and where it diverges from GitHub Actions |
| [gitlab-basics.md](CI-CD/gitlab/gitlab-basics.md) | GitLab CI pipelines, runners, variables |
| [CI-CD/github/](CI-CD/github) | GitHub Actions workflow example |
| [CI-CD/Dockerfiles/ansible-linter/](CI-CD/Dockerfiles/ansible-linter) | Linter image used by CI |

### Container Orchestration
| | |
| --- | --- |
| [k3s-Basics.md](Container%20Orchestration/k3s/k3s-Basics.md) | Single-binary Kubernetes, joining nodes, kubeconfig |
| [openshift-basics.md](Container%20Orchestration/Open%20Shift/openshift-basics.md) | OpenShift vs plain Kubernetes, `oc`, SCCs |

### Reverse proxy
| | |
| --- | --- |
| [traefik.md](reverse_proxy/traefik.md) | Routers, middleware chains, ACME, label-driven routing |
| [nginx.md](reverse_proxy/nginx.md) | Static reverse proxying, TLS, the headers you must set |

## Conventions

- **Upstream code is declared, not vendored.** Galaxy roles live in
  `requirements.yml` with a pinned version. Only locally written roles are committed.
- **Runtime state is not committed.** Certificates, logs, `.env` files and secrets are
  gitignored. A stack that writes into its own directory needs that path ignored
  before it is first run.
- **Images are pinned**, and Renovate opens a PR when a pinned version moves.
- **Every note opens with the upstream documentation link.** These notes are a
  shortcut, not a replacement.

## Renovate

Dependency updates arrive as pull requests, tracked on the **Dependency Dashboard**
issue. Note that this repo has no status checks configured, so updates gated on
"pending status checks" will wait indefinitely — approve them from the dashboard.
