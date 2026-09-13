# Supply Chain and DevSecOps

Securing what you build and deploy, as opposed to what you run it on. The shift that matters: most
of the code in production was written by someone else, so "is our code secure" is the smaller half
of the question.

## The attack surface

```
dependencies ──► build ──► image/artifact ──► registry ──► deploy ──► runtime
     ▲             ▲            ▲               ▲            ▲          ▲
 typosquats    compromised   embedded        stolen      unsigned    excess
 malicious     CI, leaked    secrets,        creds,      artifacts,  privilege
 updates       tokens        stale CVEs      tampering   no policy
```

Each arrow is a place to insert a control. The leverage is highest on the left — a malicious
dependency defeats every later control.

## Dependencies

### Pin and lock

```
package-lock.json   poetry.lock   Cargo.lock   go.sum   Chart.lock   .terraform.lock.hcl
```

**Commit every lockfile.** Without one, two builds of the same commit can resolve different
versions, which destroys reproducibility and means a review of version X can ship version Y.

```bash
npm ci          # installs exactly the lockfile — use in CI, never `npm install`
pip install -r requirements.txt --require-hashes
go mod verify
```

`npm ci` vs `npm install` matters: `install` may update the lockfile, `ci` fails if the lockfile
disagrees with the manifest. CI should use the strict form.

### The threats specific to dependencies

| Threat | Description |
| --- | --- |
| **Typosquatting** | `requets` instead of `requests` — a package that looks right |
| **Slopsquatting** | Registering package names that AI tools hallucinate. Verify every new import exists before it enters a lockfile |
| **Dependency confusion** | A public package shadowing your internal one. Scope internal packages and configure the registry to prefer them |
| **Compromised maintainer** | A legitimate package ships malicious code in a patch release |
| **Abandoned packages** | No maintainer means no patches |
| **Transitive depth** | You did not choose most of what you install |

Dependency confusion deserves a note: if your build resolves `@myorg/utils` from a public registry
before your private one, anyone can publish that name and own your build. Use scoped names plus an
explicit registry mapping.

```bash
npm audit --audit-level=high
pip-audit
govulncheck ./...
cargo audit
```

### Automated updates

Renovate or Dependabot, configured so the noise is tolerable:

```json
{
  "extends": ["config:recommended"],
  "packageRules": [
    { "matchUpdateTypes": ["minor", "patch"], "groupName": "non-major", "automerge": true },
    { "matchUpdateTypes": ["major"], "dependencyDashboardApproval": true }
  ],
  "vulnerabilityAlerts": { "labels": ["security"] },
  "ignorePaths": ["**/vendor/**", "**/roles/*/"]
}
```

Two lessons worth carrying:

- **Automerge patch updates.** A queue of 40 open PRs gets ignored, which is worse than automerging
  the low-risk ones and reviewing majors.
- **Exclude vendored third-party code.** A bot updating dependencies *inside* someone else's vendored
  library generates PRs that change nothing you run and drift the vendored copy from upstream. This
  repo hit exactly that — see
  [../Infrastructure as Code/ansible/roles/README.md](../Infrastructure%20as%20Code/ansible/roles/README.md).

## Scanning, and making it survivable

```bash
# images
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 myapp:1.4.2
grype myapp:1.4.2

# IaC misconfiguration
trivy config .
checkov -d .
tfsec .

# secrets
gitleaks detect --source .
trufflehog git file://.

# Kubernetes manifests
kubesec scan deploy.yaml
polaris audit --audit-path ./manifests
```

The design constraint: **a gate people route around is worse than no gate.** Three rules that keep
scanning useful:

1. **`--ignore-unfixed`.** Failing on vulnerabilities with no available patch produces a build nobody
   can fix, and the gate gets disabled within a week.
2. **Fail on new findings, not on the existing backlog.** Baseline what is there, block regressions.
3. **Have a documented exception path** with an expiry date. Undocumented permanent suppressions are
   where real findings go to die.

Scan at three points: in the developer's editor or pre-commit (fastest feedback), in CI (blocking),
and **continuously in the registry** — a CVE published after your build means an image that passed
is now vulnerable while nothing in your pipeline has changed.

## SBOM and provenance

An SBOM answers "are we affected by this CVE" without rebuilding or guessing.

```bash
syft myapp:1.4.2 -o spdx-json > sbom.json
syft myapp:1.4.2 -o cyclonedx-json > sbom.cdx.json

# then answer the question offline
grype sbom:./sbom.json
```

Generate it **at build time** and store it with the artifact. Generating it later from a running
image is an approximation of what you shipped.

**Provenance** — a signed statement of how the artifact was built (source commit, builder, inputs) —
is what lets a deployment require that an image came from your pipeline and not someone's laptop.

```bash
cosign sign --key cosign.key registry.example.com/myapp:1.4.2
cosign verify --key cosign.pub registry.example.com/myapp:1.4.2

# keyless, via CI's OIDC identity — no key to manage or leak
cosign sign registry.example.com/myapp:1.4.2
cosign verify registry.example.com/myapp:1.4.2 \
  --certificate-identity-regexp 'https://git.example.com/myorg/.*' \
  --certificate-oidc-issuer https://git.example.com
```

Keyless signing is the better default: the signature is bound to the CI workload's identity, so
there is no signing key to steal.

Enforce it at admission, or signing accomplishes nothing:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature
      match:
        any:
          - resources: { kinds: [Pod] }
      verifyImages:
        - imageReferences: ["registry.example.com/*"]
          attestors:
            - entries:
                - keys: { publicKeys: |- 
                    -----BEGIN PUBLIC KEY-----
                    ...
                    ----- END PUBLIC KEY-----
                  }
```

### SLSA, briefly

A maturity framework for build integrity. The useful progression, stripped of the formalism:

1. Builds are scripted and produce provenance.
2. Builds run on a hosted service; provenance is signed.
3. The build platform is hardened; provenance is non-falsifiable.

Most teams benefit from reaching "builds only happen in CI, from a committed source, and the result
is signed". That eliminates the laptop-built image, which is the realistic threat.

## Securing the pipeline

CI is a high-value target: it has credentials to everything and executes code from your repo.

- **No long-lived cloud keys.** OIDC federation, scoped to one repo and ideally one branch. See
  [../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md).
- **Pin actions by SHA**, not tag. A tag is mutable; `uses: someone/action@v3` runs whatever they
  push to `v3` today.
  ```yaml
  - uses: https://data.forgejo.org/actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
  ```
- **Minimal permissions per job.** Default to read; grant write only where needed.
- **Never run untrusted PR code with secrets.** A fork's pull request must not get access to
  credentials — this is what `pull_request_target` misuse exposes.
- **Protect branches.** Require review and passing checks; restrict who can push to `main`.
- **Separate build from deploy.** Build produces a signed artifact; deploy consumes it. Better still,
  deploy via GitOps so CI holds no cluster credentials at all — see
  [../GitOps/gitops-principles.md](../GitOps/gitops-principles.md).
- **Pin runner images** and set `force_pull` so you know what you are executing on.

## Runtime enforcement

Scanning is advisory; admission control is a boundary.

```yaml
# Kyverno: block the most common mistakes
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: baseline
spec:
  validationFailureAction: Enforce
  rules:
    - name: disallow-latest-tag
      match: { any: [{ resources: { kinds: [Pod] } }] }
      validate:
        message: "Images must be tagged, not :latest"
        pattern:
          spec:
            containers:
              - image: "!*:latest"
    - name: require-registry
      match: { any: [{ resources: { kinds: [Pod] } }] }
      validate:
        message: "Images must come from the approved registry"
        pattern:
          spec:
            containers:
              - image: "registry.example.com/*"
```

Plus Pod Security Admission for the workload-hardening baseline, which is built in and needs no
extra controller:

```bash
kubectl label namespace prod \
  pod-security.kubernetes.io/enforce=restricted
```

See
[../Container Orchestration/kubernetes/kubernetes-rbac-and-security.md](../Container%20Orchestration/kubernetes/kubernetes-rbac-and-security.md).

Roll out policy as `audit`/`warn` first. Going straight to `Enforce` on an existing namespace blocks
the next deploy, and the usual response is to disable the policy.

## Vulnerability triage

A scanner reporting 400 findings is not 400 problems. Prioritise by:

1. **Is it reachable?** A CVE in a code path you never call is lower risk than its score suggests.
   Reachability analysis (`govulncheck`, Snyk) answers this; CVSS alone does not.
2. **Is it exploitable in context?** A container with no network listener and no shell changes the
   picture.
3. **Is it in KEV?** CISA's Known Exploited Vulnerabilities catalogue is actual observed exploitation,
   which beats a severity score for prioritisation.
4. **Is there a fix?** If not, it is a risk decision, not a work item.

Most findings are in the base image, so **updating and rebuilding on a schedule** removes more
vulnerabilities than any amount of triage. A weekly rebuild of a slim base is the single most
effective control here.

## A baseline worth adopting

Roughly in order of value per effort:

- [ ] Lockfiles committed; CI installs strictly from them
- [ ] Secret scanning in pre-commit **and** CI
- [ ] Renovate/Dependabot with patch automerge and vendored paths excluded
- [ ] Base images pinned by digest, rebuilt weekly
- [ ] Image scanning in CI with `--ignore-unfixed`, failing on new findings only
- [ ] No long-lived cloud credentials — OIDC federation
- [ ] CI actions pinned by SHA, minimal job permissions
- [ ] Branch protection with required review
- [ ] SBOM generated at build and stored with the artifact
- [ ] Images signed (keyless) and verified at admission
- [ ] Pod Security Admission `restricted` where workloads tolerate it
- [ ] Registry scanned continuously, not only at build
- [ ] Documented exception process with expiry dates

The first four cost very little and remove the most common real incidents: a leaked credential, an
unpatched base image, and a malicious or confused dependency.

## Related

- [../Containers/docker/dockerfile-best-practices.md](../Containers/docker/dockerfile-best-practices.md) — build secrets, scanning, multi-stage
- [../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md) — OIDC, leak response
- [../Container Orchestration/kubernetes/kubernetes-rbac-and-security.md](../Container%20Orchestration/kubernetes/kubernetes-rbac-and-security.md)
- [../AI/ai-for-development.md](../AI/ai-for-development.md) — hallucinated dependencies
- [../GitOps/gitops-principles.md](../GitOps/gitops-principles.md)
