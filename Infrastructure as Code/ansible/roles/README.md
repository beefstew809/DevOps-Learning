# Roles

Only **locally written** roles live in this directory. Roles pulled from Ansible
Galaxy are declared in [`../requirements.yml`](../requirements.yml) and installed
on demand — they are deliberately not committed here.

## Local roles

| Role | What it does |
| --- | --- |
| `configure-autofs` | Installs autofs and writes the NFS automount maps. |
| `setup-dockerhealth-systemd-service` | Installs a systemd unit + timer that restarts unhealthy containers. |

## Why Galaxy roles are not vendored

They used to be. Five of them — `artis3n.tailscale`, `geerlingguy.docker`,
`diodonfrost.terraform`, `GROG.package`, `GROG.fqdn` — were committed in full,
about 170 files. That caused three concrete problems:

1. **Dependency bot noise.** Renovate scanned the vendored roles' own
   `poetry.lock`, `pyproject.toml` and `.github/workflows/*`, and opened pull
   requests to upgrade *other projects' test tooling*. Six of eight open PRs at
   one point were molecule and ansible-lint bumps inside
   `artis3n.tailscale` — changes that affect nothing here.
2. **Silent drift.** Once a bot edits vendored code, the directory no longer
   matches any upstream release, so you cannot tell what version you actually
   have or diff it against upstream.
3. **No version record.** A vendored copy pins nothing. The only trace of the
   version was `meta/.galaxy_install_info`, a file `ansible-galaxy` writes for
   its own bookkeeping — not something you would think to read.

Declaring them in `requirements.yml` fixes all three: the version is explicit and
reviewable, Renovate manages that one file instead of hundreds, and upstream code
stays upstream.

## Installing

```sh
cd "Infrastructure as Code/ansible"
ansible-galaxy install -r requirements.yml
```

Add `--force` to re-install when you bump a version in `requirements.yml`.

## Writing a new local role

Keep it here, give it a `defaults/main.yml` with every variable it reads, and a
`meta/main.yml` declaring its platforms. `ansible-galaxy role init <name>`
scaffolds the layout.
