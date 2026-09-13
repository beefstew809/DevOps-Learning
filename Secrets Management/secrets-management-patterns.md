# Secrets Management Patterns

Choosing how to handle credentials, before reaching for a tool. Vault is powerful and often
more than a given situation needs; the wrong choice is usually either "plaintext in git" or
"a distributed secrets platform to hold four passwords".

## What counts as a secret

Anything that grants access: passwords, API tokens, private keys, TLS keys, database
connection strings, webhook signing keys, cloud access keys, SSH keys, session secrets.

Not secrets, though often treated as such: hostnames, usernames without passwords, public
keys, bucket names, account IDs. Treating these as secrets makes configuration harder
without improving security — and hiding them encourages the real secrets to be handled
casually alongside.

## The hierarchy, worst to best

```
1. Hardcoded in source                  committed, permanent, in every clone and fork
2. Plaintext config file in git         same, with a directory to hide in
3. Environment variables in CI config   better; visible in logs if echoed
4. Encrypted in git (SOPS, sealed)      decryptable only with a key you control
5. Secret manager, static secrets       centralised, audited, rotatable
6. Secret manager, dynamic secrets      short-lived, per-consumer, individually revocable
7. No secret at all (workload identity) nothing to leak
```

Most teams should aim for 4 or 5. **7 is the real goal where the platform supports it** —
IAM roles for service accounts, Kubernetes ServiceAccount tokens, OIDC federation from CI.
If the cloud can assert your identity, no credential needs to exist.

## Decision guide

| Situation | Use |
| --- | --- |
| CI needs to push to a cloud | **OIDC federation** — no stored keys at all |
| Pod needs a cloud API | **Workload identity** (IRSA, Workload Identity) |
| Kubernetes app, secrets in git | **SOPS** or **Sealed Secrets** |
| Kubernetes app, chart wants `secretRef` | **External Secrets Operator** |
| Kubernetes app, no Secret should exist | **Vault Agent injector** or **CSI** |
| Database credentials, short-lived | **Vault database engine** |
| A handful of homelab compose secrets | **`.env` files, gitignored, backed up** |
| Ansible variables | **ansible-vault** |
| Team password sharing | **A password manager** — not any of the above |

That last row matters. Vault is not a password manager for humans; a password manager is
not a secrets backend for applications. Conflating them produces both a bad UX and bad
automation.

## OIDC federation: the one to adopt first

If your CI pushes to AWS, GCP or Azure, stop storing access keys. The CI system presents a
signed token asserting which repo and branch is running, and the cloud trades it for
short-lived credentials.

```yaml
# GitHub Actions → AWS, no secrets stored
permissions:
  id-token: write
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789012:role/ci-deploy
      aws-region: us-east-1
```

The trust policy scopes it to one repo, and usually one branch:

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:sub": "repo:myorg/myrepo:ref:refs/heads/main"
    }
  }
}
```

**Scope the `sub` condition.** `repo:myorg/*` trusts every repo in the org; a wildcard that
matches `pull_request` lets a fork's PR assume the role. This is the main way OIDC setups
go wrong.

Nothing is stored, nothing expires, nothing leaks. Where it is available it dominates every
other option.

## Encrypted-in-git

### SOPS

Encrypts **values**, leaving keys and structure readable — so diffs stay meaningful:

```bash
brew install sops age          # or dnf install
age-keygen -o key.txt

sops --encrypt --age <public-key> secrets.yaml > secrets.enc.yaml
sops secrets.enc.yaml          # opens $EDITOR, re-encrypts on save
sops --decrypt secrets.enc.yaml
```

```yaml
# .sops.yaml — so you never pass --age by hand
creation_rules:
  - path_regex: .*\.enc\.yaml$
    encrypted_regex: '^(data|stringData|password|token)$'
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

Strengths: works with any file format, plain git workflow, and `encrypted_regex` keeps
non-secret fields legible. Weakness: the decryption key is your problem. Use age keys per
environment, or back it with cloud KMS so access is IAM-controlled and audited.

### Sealed Secrets

A controller in the cluster publishes a public key; you encrypt with it and only the
controller can decrypt.

```bash
kubeseal --fetch-cert > pub.pem
kubectl create secret generic db --dry-run=client -o yaml \
  --from-literal=password=s3cret \
  | kubeseal --cert pub.pem -o yaml > sealed-db.yaml
```

Simpler than SOPS — no key for you to hold. The trade-off is that ciphertext is tied to
that controller's key, so it does not move between clusters, and **losing the controller's
key makes every sealed secret unrecoverable**. Back up the sealing key:

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealing-key-backup.yaml
```

That backup is itself a critical secret. Treat it like a Vault unseal share.

## Rotation

The part everyone skips. A secret you cannot rotate quickly is a secret you cannot respond
to an incident with.

Design for it:

- **Two valid credentials at once.** The only way to rotate without downtime: add the new
  one, deploy, remove the old. A single-credential design forces a simultaneous cutover.
- **Know every consumer.** Rotation fails when an unknown service still uses the old value.
  Write down consumers as part of creating a secret.
- **Automate or it will not happen.** Dynamic secrets make rotation the default; static
  secrets need a scheduled job and an owner.
- **Practise it.** Rotate something on purpose while nothing is wrong.

## Leaked secret: what to actually do

Order matters, and the first step is the one people get wrong.

1. **Revoke it.** Immediately. Not "rotate later" — revoke now. A leaked credential is
   live until revoked.
2. **Check for use.** Audit logs, cloud CloudTrail, database connections. Assume it was
   found.
3. **Issue a replacement** and deploy.
4. **Then** clean up the leak.

**Removing a secret from git history does not un-leak it.** If it was pushed, assume it is
in someone's clone, a fork, a CI log, and an automated scraper's database. `git filter-repo`
or BFG rewrites history, which breaks everyone's clones and is worth doing for hygiene —
but only after revocation, and never instead of it.

```bash
# prevention is cheaper
gitleaks detect --source .
trufflehog git file://.
```

Put one of those in CI and in a pre-commit hook. Scanning catches the commit before it is
pushed, which is the only point at which the cleanup is cheap.

## Anti-patterns

| Pattern | Why it fails |
| --- | --- |
| Secrets in container images | Present in every layer and every pull; `docker history` shows build args |
| Secrets in `docker build --build-arg` | Recorded in image metadata. Use BuildKit `--mount=type=secret` |
| Secrets in Kubernetes env vars | Visible in `kubectl describe`, `/proc/*/environ`, and crash dumps |
| Secrets in CI logs | `echo $TOKEN` defeats masking; so does any tool printing its config |
| One shared secret for everything | Cannot revoke one consumer; rotation is an outage |
| Long-lived cloud access keys | The single most common cause of cloud compromise |
| `chmod 777` on a secret file | Any local process reads it |
| Base64 treated as encryption | It is encoding. Kubernetes Secrets and Podman secrets are both base64 |

That last one is worth repeating because two tools in this repo do it: Kubernetes Secrets
and Podman's default `file` secret driver both store base64, not ciphertext.

## Homelab-scale pragmatism

Being honest: for a handful of compose stacks, Vault is more operational burden than the
risk it removes. A defensible small setup:

- `.env` files next to each compose file, in `.gitignore`, mode `600`.
- An `.env.example` committed with keys and dummy values, so the shape is documented.
- Those files included in the host backup — because losing them means rebuilding every
  service's configuration from memory.
- `gitleaks` in CI so a secret never lands in the repo by accident.
- Real secret management introduced where it earns its place: anything internet-facing,
  anything with a blast radius beyond one container, and database credentials.

The failure mode to avoid is not "no Vault" — it is secrets that exist only in a running
container's environment, documented nowhere, and absent from backups.

## Related

- [vault-basics.md](vault-basics.md)
- [vault-kubernetes.md](vault-kubernetes.md)
- [../GitOps/gitops-principles.md](../GitOps/gitops-principles.md)
- [../Containers/docker/dockerfile-best-practices.md](../Containers/docker/dockerfile-best-practices.md) — build secrets
