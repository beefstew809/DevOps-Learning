# Forgejo Actions

https://forgejo.org/docs/latest/user/actions/

Forgejo's CI. It reuses GitHub Actions *syntax* but is a separate implementation, so
most workflows port with small changes — and a handful of differences cause the
failures that cost the most time.

Workflows live in `.forgejo/workflows/*.yml`. (Forgejo will also read
`.github/workflows/`, which is handy when migrating but means a repo can
accidentally run both.)

## Differences from GitHub Actions that actually bite

### 1. `uses:` is not implicitly github.com

GitHub resolves `actions/checkout@v4` against github.com. Forgejo does not assume a
host — give it a full URL:

```yaml
# Works
- uses: https://data.forgejo.org/actions/checkout@v5
- uses: https://github.com/tailscale/github-action@v4

# Resolves against your own Forgejo instance, and usually 404s
- uses: actions/checkout@v4
```

`data.forgejo.org` mirrors the common actions. Pin to a SHA with the version in a
trailing comment — Renovate reads that form and keeps it current:

```yaml
- uses: https://data.forgejo.org/actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
```

### 2. Runner labels select an image, not just a machine

A label maps to a container image in the runner's config:

```yaml
labels:
  - "docker:docker://catthehacker/ubuntu:act-latest"
  - "build:docker://catthehacker/ubuntu:act-latest"
  - "tailscale:docker://catthehacker/ubuntu:act-latest"
```

So `runs-on: docker` already lands in an image carrying `jq`, `ssh` and the docker
CLI — no `container:` override needed. `ubuntu-latest` is *not* special; it only
works if a runner declares that label.

Labels are also how you pin work to a host. A label offered by only one host is the
simplest way to keep a job near something only that host can reach — a builder on
an unpublished port, for instance. Worth knowing that a label grants a *capability*;
it does not by itself guarantee anything about the network the job lands in.

### 3. Registering a runner

`forgejo-runner register` is deprecated and **404s against Forgejo 16**. Create the
runner in the web UI instead (Site Administration → Runners, or per-repo settings),
then put the credentials in a config file:

```yaml
server:
  connections:
    myinstance:
      url: http://forgejo.example.ts.net:3000
      uuid: "<from the UI>"
      token: "<from the UI>"
```

Point runners at the internal address, not a public/CDN hostname — the job
containers need to reach the instance directly to fetch the repo and report status.

### 4. The runner image has no ENTRYPOINT

Compose must name the binary, or the container starts and immediately exits:

```yaml
services:
  forgejo-runner:
    image: code.forgejo.org/forgejo/runner:9
    command: ["forgejo-runner", "daemon", "--config", "/config.yml"]
    volumes:
      - ./config.yml:/config.yml:ro
```

### 5. `container.force_pull` defaults to false — set it to true

```yaml
container:
  force_pull: true
  network: docker_net
```

This one is worth the paragraph. With `force_pull: false`, the runner pulls a job
image only when no local image already carries that tag. If your job containers are
`:latest` — and `catthehacker/ubuntu:act-latest` is — then once a tag is resident the
runner **never refreshes it**. You rebuild an image, push it, and jobs keep running
the old one indefinitely.

The failure is badly misleading: a successful build and push, followed by a job that
fails on a tool the *new* image contains. Everything points at the image being wrong
when it was simply never fetched. The tell is **version skew between jobs** — e.g.
`git 2.55.0` in one job and `git 2.39.5` in another, meaning two different bases.

Cost of enabling it is one manifest round-trip per job, not a re-download.

### 6. Verifying config: `generate-config` shows DEFAULTS, not what is loaded

```bash
# WRONG — emits a fresh default template, so it reports force_pull: false
# even on a runner that has it set and is honouring it
docker exec <runner> forgejo-runner generate-config

# RIGHT — read the config the runner actually mounted
docker exec <runner> grep force_pull /config.yml
```

Also: the runner reads its config at daemon start, so a config change needs a
restart — and a restart **cancels any in-flight job**.

### 7. A runner that needs the tailnet needs extra capabilities

```yaml
container:
  options: "--device /dev/net/tun --cap-add NET_ADMIN"
```

Without those, `tailscale up` inside the job fails in a way that reads like an auth
problem.

## Reusable workflows

Same mechanism as GitHub, addressed by `owner/repo`:

```yaml
jobs:
  deploy:
    uses: myorg/ci-workflows/.forgejo/workflows/deploy.yml@main
    with:
      host: docker1
    secrets: inherit
```

The called workflow needs `on: workflow_call:` with matching `inputs:` and
`secrets:`. `secrets: inherit` passes the caller's secrets straight through, which
avoids restating each one.

## Secrets and variables

Repo or org → Settings → Actions → Secrets / Variables. Secrets are write-only and
masked in logs; variables are plain text and readable. `${{ secrets.NAME }}` and
`${{ vars.NAME }}` as on GitHub.

`GITHUB_TOKEN` exists, scoped to the repo, and `github.*` context names are kept for
compatibility — `${{ github.event_name }}` works. Forgejo also exposes `forgejo.*`.

## Debugging

```bash
docker logs -f <runner>                    # registration and job pickup
docker exec <runner> cat /config.yml       # what it actually loaded
```

- **Job stuck pending:** no runner offers that `runs-on` label, or concurrency is
  full. `concurrent` in the runner config caps simultaneous jobs.
- **Cannot clone:** the job container cannot resolve the Forgejo host. Check
  `container.network` is a network that resolves it — and note that a network name
  like `docker_net` is a *different network on every host*, so this cannot be copied
  between hosts unchanged.
- **Action not found:** an unqualified `uses:`. See difference 1.
- **Stale tool versions:** `force_pull`. See difference 5.

## Notes

- A `push` event gives `github.event.before`, but it is all zeroes on the first push
  to a new branch and on `workflow_dispatch` — any "what changed since last time"
  logic needs a fallback, or it will behave as though everything changed.
- GitLab CI is a different syntax entirely — see
  [../gitlab/gitlab-basics.md](../gitlab/gitlab-basics.md).
