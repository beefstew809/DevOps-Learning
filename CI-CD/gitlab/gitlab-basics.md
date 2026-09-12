# Gitlab

https://docs.gitlab.com/ee/ci/

## GitLab CI

Pipelines are defined in `.gitlab-ci.yml` at the repo root. There is an example in
this repo at
[../Dockerfiles/ansible-linter/.gitlab-ci.yml](../Dockerfiles/ansible-linter/.gitlab-ci.yml).

### Structure

```yaml
stages:
  - lint
  - build
  - deploy

variables:
  REGISTRY: registry.example.com/your-namespace

lint-yaml:
  stage: lint
  image: python:3.12-slim
  script:
    - pip install yamllint
    - yamllint .

build-image:
  stage: build
  image: quay.io/podman/stable
  script:
    - podman build -t "$REGISTRY/ansible-linter:$CI_COMMIT_SHORT_SHA" .
    - podman push "$REGISTRY/ansible-linter:$CI_COMMIT_SHORT_SHA"
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

Jobs in the same stage run in parallel; stages run in order. A failing job fails its
stage and stops the ones after it, unless you set `allow_failure: true`.

### Key pieces

| Keyword | What it does |
| --- | --- |
| `image` | Container the job runs in |
| `script` | Commands. Non-zero exit fails the job. |
| `before_script` | Runs before `script`, same shell |
| `rules` / `if` | Whether the job is created at all |
| `needs` | Run as soon as named jobs finish, ignoring stage order |
| `artifacts` | Files to keep and pass to later stages |
| `cache` | Paths to reuse between runs (not guaranteed to exist) |
| `services` | Extra containers, e.g. a database |

`artifacts` and `cache` get confused often: artifacts are outputs you want to keep
and hand downstream, cache is a speed optimisation that may be cold. Never depend on
cache contents being present.

### Useful predefined variables

```
CI_COMMIT_BRANCH        branch name
CI_COMMIT_SHORT_SHA     8-char sha, good for image tags
CI_DEFAULT_BRANCH       usually main
CI_PIPELINE_SOURCE      push, merge_request_event, schedule, web
CI_PROJECT_DIR          checkout path
CI_REGISTRY_IMAGE       the project's registry path
```

### Rules

`rules` replaced `only`/`except`. Evaluated top to bottom, first match wins:

```yaml
rules:
  - if: $CI_PIPELINE_SOURCE == "merge_request_event"
  - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    when: manual
  - when: never
```

## Runners

Jobs need a runner registered to the project or group. The `docker` executor is the
usual choice — each job gets a fresh container.

```bash
sudo gitlab-runner register \
  --url https://gitlab.example.com/ \
  --token glrt-REDACTED \
  --executor docker \
  --docker-image alpine:latest
```

Config lands in `/etc/gitlab-runner/config.toml`. `concurrent` there is a global cap
on simultaneous jobs and defaults to 1, which is the usual reason a pipeline appears
to hang with jobs stuck pending.

## Secrets

Project → Settings → CI/CD → Variables. Mark them **Masked** so they are redacted
from logs, and **Protected** so they are only exposed to protected branches and tags.

Masking has rules — the value must be a single line, at least 8 characters, and
base64-ish. A value that fails them is silently not masked, so check that the
checkbox actually stuck.

## Validating before you push

GitLab lints `.gitlab-ci.yml` at **CI/CD → Editor → Validate**, which catches schema
errors without burning a pipeline run. Locally, yamllint only catches YAML syntax,
not GitLab's schema.

## Notes

- The `REGISTRY` value in this repo's example is a placeholder
  (`registry.example.com/your-namespace`) and is marked `# Registry TBD`. Point it at
  a real registry before expecting that job to run.
- Forgejo Actions uses GitHub Actions syntax, not this — see
  [../forgejo/forgejo-actions.md](../forgejo/forgejo-actions.md).
