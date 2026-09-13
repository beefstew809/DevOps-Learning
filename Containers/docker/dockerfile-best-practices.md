# Dockerfile Best Practices

https://docs.docker.com/build/building/best-practices/

Everything here applies equally to `podman build` and `buildah build` — the format is the OCI
Containerfile either way. See [../Podman/buildah.md](../Podman/buildah.md).

Three goals, usually aligned: **small images**, **fast rebuilds**, **no secrets or
vulnerabilities baked in**.

## Layer caching: the model

Each instruction creates a layer. A layer is reused only if the instruction and everything
before it are unchanged. **One invalidated layer invalidates every layer after it.**

So ordering decides rebuild speed: put what rarely changes first, what changes constantly last.

```dockerfile
# BAD — any source change re-runs npm install
FROM node:22-slim
WORKDIR /app
COPY . .
RUN npm ci
CMD ["node", "server.js"]

# GOOD — dependencies cached until the manifests change
FROM node:22-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
CMD ["node", "server.js"]
```

That reordering is usually the single largest build-time win available. The same pattern applies
everywhere: `go.mod`/`go.sum`, `requirements.txt`, `Cargo.toml`, `pom.xml`.

### Cache mounts

BuildKit can persist a directory across builds without it entering the image:

```dockerfile
RUN --mount=type=cache,target=/root/.npm npm ci
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends curl
```

Now even a dependency change reuses the download cache. Note that with a cache mount for apt you
should **not** `rm -rf /var/lib/apt/lists/*` — the mount is not in the image anyway.

## Multi-stage builds

Build tooling should not ship to production. Compile in one stage, copy the artifact into a
clean one:

```dockerfile
FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/app ./cmd/app

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

A Go binary this way is a few MB instead of ~900 MB. The compiler, module cache and source never
reach the final image — so they are not a vulnerability surface and not a leak risk.

For interpreted languages the same idea applies to build dependencies:

```dockerfile
FROM python:3.13-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc python3-dev \
 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.13-slim
COPY --from=build /install /usr/local
COPY . /app
WORKDIR /app
USER 1000:1000
CMD ["python", "-m", "myapp"]
```

`gcc` is needed to build wheels and is not needed to run them.

Target a specific stage for debugging or CI:

```bash
docker build --target build -t myapp:build .
```

## Base image choice

| Base | Size | Trade-off |
| --- | --- | --- |
| `debian:12-slim` | ~75 MB | Familiar, glibc, has a shell |
| `alpine:3.21` | ~8 MB | musl libc — **can break Python wheels and Go cgo** |
| `gcr.io/distroless/*` | ~2–20 MB | No shell, no package manager. Minimal surface |
| `scratch` | 0 | Static binaries only |
| `ubi9-minimal` | ~100 MB | Red Hat ecosystem |

Alpine's musl is the gotcha: pre-built Python wheels target glibc, so Alpine often compiles from
source — slower builds, occasional runtime differences. The size saving is frequently not worth
it for Python.

Distroless has no shell, so `docker exec … sh` fails. That is a security property, not a bug;
debug with `kubectl debug` or the `:debug` tag variant. See
[../../Container Orchestration/kubernetes/kubernetes-troubleshooting.md](../../Container%20Orchestration/kubernetes/kubernetes-troubleshooting.md).

### Pin properly

```dockerfile
FROM node:22                # floats — rebuilds are not reproducible
FROM node:22.11-slim        # better
FROM node:22.11-slim@sha256:1a2b3c...   # exact, what Renovate manages
```

Digest pinning is what makes a rebuild produce the same base. Renovate updates these
automatically, which is how the pins in this repo stay current.

## Run as non-root

```dockerfile
RUN useradd --system --uid 10001 --no-create-home appuser
USER 10001:10001
```

Use a **numeric** UID in `USER`. Kubernetes' `runAsNonRoot` check cannot resolve a username to a
UID, so `USER appuser` fails the check even though the image is correct.

Consequences to handle: a non-root process cannot bind ports below 1024 (listen on 8080), and
cannot write to directories owned by root — so `chown` what it needs at build time:

```dockerfile
RUN mkdir -p /app/data && chown 10001:10001 /app/data
```

## Secrets in builds

**Never use `ARG` or `ENV` for secrets.** Build args are recorded in image metadata:

```bash
docker history --no-trunc myapp:latest | grep -i token   # it is right there
```

And `ENV` persists into every container. Deleting the file in a later layer does not help —
earlier layers remain in the image.

BuildKit secret mounts are the answer. The file exists only during that `RUN`:

```dockerfile
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm ci
```

```bash
docker build --secret id=npmrc,src=$HOME/.npmrc -t myapp .
```

For private git dependencies, forward the SSH agent rather than copying a key:

```dockerfile
RUN --mount=type=ssh git clone git@github.com:org/private.git
```

```bash
docker build --ssh default -t myapp .
```

## .dockerignore

```
.git
node_modules
__pycache__
*.pyc
.env
.venv
dist
target
*.log
.terraform
**/*.tfstate*
Dockerfile
.dockerignore
```

This does two jobs. It shrinks the build context — `COPY . .` with a 500 MB `.git` is slow and
bloats the image. And it **prevents secrets leaking**: without `.env` and `*.tfstate` excluded,
`COPY . .` bakes credentials into a layer.

Treat a missing `.dockerignore` as a security finding, not just a performance one.

## CMD vs ENTRYPOINT

```dockerfile
ENTRYPOINT ["/app"]           # always runs
CMD ["--config", "/etc/app.yaml"]   # default args, overridable
```

Use **exec form** (JSON array), not shell form. Shell form wraps the process in `/bin/sh -c`,
which means:

- The app becomes PID 2 and **does not receive SIGTERM** — so graceful shutdown never happens and
  every stop takes the full 30-second kill timeout.
- An extra shell process in the container.

```dockerfile
CMD ["node", "server.js"]      # app is PID 1, gets signals
CMD node server.js             # sh is PID 1, app does not get SIGTERM
```

This is a real production problem: slow rolling updates and dropped in-flight requests trace
back to shell-form CMD more often than people expect.

If the process does not reap children (common with Node and Python spawning subprocesses), add
an init:

```bash
docker run --init myapp        # or tini in the image
```

## Health checks

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/app", "healthcheck"]
```

Useful for Docker and Compose. **Kubernetes ignores `HEALTHCHECK`** entirely — it uses probes
from the pod spec. Define both if the image runs in both places.

Prefer a check that does not require `curl` in the image, so you can still use a minimal base.

## Combine layers, but sensibly

```dockerfile
# 3 layers, and the cleanup layer does not shrink the image
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*

# 1 layer, actually smaller
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
```

Deletion in a *later* layer does not reclaim space — the data is still in the earlier layer. The
cleanup must be in the same `RUN`.

`--no-install-recommends` alone often saves tens of MB.

But do not over-combine: a single 40-line `RUN` is one cache unit, so any change re-runs
everything. Group by what changes together.

## Build-time checks

```bash
# lint
hadolint Dockerfile

# scan for CVEs, fail the build on fixable ones
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 myapp:latest

# SBOM, so "are we affected by X" is answerable without rebuilding
syft myapp:latest -o spdx-json > sbom.json

# sign, so deployment can require provenance
cosign sign --key cosign.key registry.example.com/myapp:1.4.2
```

`--ignore-unfixed` matters for a gate that people will not route around: failing on
vulnerabilities with no available patch produces a build nobody can fix, and the gate gets
disabled.

This repo already runs hadolint in
[../../CI-CD/Dockerfiles/ansible-linter/.gitlab-ci.yml](../../CI-CD/Dockerfiles/ansible-linter/.gitlab-ci.yml).

## Multi-arch

Worth doing since Graviton and Apple Silicon are both ARM:

```bash
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 \
  -t registry.example.com/myapp:1.4.2 --push .
```

Use `TARGETARCH` rather than cross-compiling by hand:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.24 AS build
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /out/app .
```

`--platform=$BUILDPLATFORM` on the build stage keeps compilation native (fast) while producing a
foreign binary. Without it, BuildKit emulates the target under QEMU, which can be 10× slower.

## A complete example

```dockerfile
# syntax=docker/dockerfile:1
FROM node:22.11-slim@sha256:abc123... AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev

FROM node:22.11-slim@sha256:abc123... AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm run build

FROM node:22.11-slim@sha256:abc123...
ENV NODE_ENV=production
RUN useradd --system --uid 10001 --no-create-home app
WORKDIR /app
COPY --from=deps  --chown=10001:10001 /app/node_modules ./node_modules
COPY --from=build --chown=10001:10001 /app/dist ./dist
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD ["node", "dist/health.js"]
ENTRYPOINT ["node", "dist/server.js"]
```

The `# syntax=` line opts into the current BuildKit frontend, which is what enables cache and
secret mounts.

## Checklist

- Dependency manifests copied before source
- Multi-stage; no compilers in the final image
- Base image pinned by digest
- `USER` with a numeric non-root UID
- Exec-form `ENTRYPOINT`/`CMD`
- `.dockerignore` excluding `.git`, `.env`, state files
- Secrets via `--mount=type=secret`, never `ARG`
- Cleanup in the same `RUN` as the install
- `--no-install-recommends` / `--no-cache-dir`
- hadolint and trivy in CI
- Multi-arch if anything runs on ARM

## Related

- [docker-basics.md](docker-basics.md)
- [../Podman/buildah.md](../Podman/buildah.md)
- [../../Secrets Management/secrets-management-patterns.md](../../Secrets%20Management/secrets-management-patterns.md)
- [../../Container Orchestration/kubernetes/kubernetes-rbac-and-security.md](../../Container%20Orchestration/kubernetes/kubernetes-rbac-and-security.md)
