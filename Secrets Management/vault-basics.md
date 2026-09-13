# Vault

https://developer.hashicorp.com/vault/docs

A secrets manager whose central idea is that **secrets should be short-lived and issued
on demand**, not stored and distributed. Vault can hold static secrets like any vault,
but its distinctive capability is generating credentials that expire — a database password
valid for one hour, issued to one application, revocable individually.

## The model

```
                      ┌─ auth methods ──┐  how a client proves identity
client ──────────────►│ kubernetes      │  (k8s SA token, AppRole, OIDC, token)
                      │ approle, oidc   │
                      └────────┬────────┘
                               │ issues a token with policies attached
                      ┌────────▼────────┐
                      │    policies     │  what paths that token may touch
                      └────────┬────────┘
                      ┌────────▼────────┐
                      │ secrets engines │  kv, database, pki, transit, aws
                      └─────────────────┘
```

Four things to keep straight: **auth methods** authenticate, **policies** authorize,
**secrets engines** produce secrets, and **tokens** carry the result. Everything in Vault
is a path, and policy is written against paths.

## Seal and unseal

Vault starts **sealed**. Its storage is encrypted and it does not hold the key — it cannot
read its own data until unsealed. This is the property that makes Vault different from a
database with a password column.

```bash
vault operator init -key-shares=5 -key-threshold=3
```

That prints five unseal key shares and an initial root token, **once**. Shamir's Secret
Sharing splits the master key so any three of five reconstruct it. Lose the shares and the
data is unrecoverable — there is no reset.

```bash
vault operator unseal     # run 3 times, different share each time
vault status
```

Every restart re-seals. That is operationally painful, so production uses **auto-unseal**
via a cloud KMS or a transit engine on another Vault:

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-unseal"
}
```

Auto-unseal trades "three humans with shares" for "the KMS key", which is usually the
right trade. Keep the Shamir shares as the recovery path regardless, distributed to
different people and not in the same password manager.

### Dev mode

```bash
vault server -dev -dev-root-token-id=root
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN=root
```

In-memory, unsealed, root token fixed. Fine for learning, and everything is lost on exit —
which is the point. Never anywhere real.

## Secrets engines

```bash
vault secrets list
vault secrets enable -path=secret kv-v2
```

### KV v2 — static secrets

```bash
vault kv put secret/myapp/db username=app password=s3cret
vault kv get secret/myapp/db
vault kv get -field=password secret/myapp/db
vault kv get -format=json secret/myapp/db | jq -r .data.data.password

vault kv put secret/myapp/db password=newpass      # creates version 2
vault kv get -version=1 secret/myapp/db
vault kv rollback -version=1 secret/myapp/db
vault kv metadata get secret/myapp/db
```

**The v1/v2 path difference trips everyone.** The CLI hides it; the API does not. For KV v2
the real paths insert a segment:

```
CLI:           secret/myapp/db
API (read):    secret/data/myapp/db
API (delete):  secret/metadata/myapp/db
```

Policies are written against API paths, so a policy granting `secret/myapp/*` does nothing
for a KV v2 mount. It must be `secret/data/myapp/*`. This is the most common Vault policy
bug.

`vault kv delete` is soft — data is recoverable until `vault kv destroy` or
`vault kv metadata delete`.

### Database — dynamic credentials

The feature worth learning Vault for. Vault creates a real database user per request, with
a lease, and drops it at expiry.

```bash
vault secrets enable database

vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres:5432/app?sslmode=require" \
  allowed_roles="readonly" \
  username="vault_admin" password="..."

vault write database/roles/readonly \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
                       GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" max_ttl="24h"

vault read database/creds/readonly
```

Returns a fresh username and password with a `lease_id`. Rotate Vault's own admin
credential immediately after configuring so nobody holds it:

```bash
vault write -force database/rotate-root/postgres
```

After that, only Vault knows that password. Note the consequence: you cannot log in as
that user any more, so keep a separate break-glass account.

### PKI — internal certificates

```bash
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki
vault write pki/root/generate/internal common_name="example.internal" ttl=87600h
vault write pki/roles/internal allowed_domains="example.internal" \
  allow_subdomains=true max_ttl="720h"

vault write pki/issue/internal common_name="app.example.internal" ttl="24h"
```

Short-lived internal TLS without running your own CA by hand. Pairs with cert-manager,
which can use Vault as an issuer.

### Transit — encryption as a service

Vault holds the key and never returns it; you send plaintext and get ciphertext back. The
application can encrypt data without ever possessing a key.

```bash
vault secrets enable transit
vault write -f transit/keys/myapp
vault write transit/encrypt/myapp plaintext=$(echo -n "card number" | base64)
vault write transit/decrypt/myapp ciphertext="vault:v1:..."
```

Key rotation re-wraps without re-encrypting your data store:

```bash
vault write -f transit/keys/myapp/rotate
```

This is also what other Vaults use for auto-unseal.

## Policies

HCL, deny by default, written against API paths:

```hcl
# myapp-policy.hcl
path "secret/data/myapp/*" {
  capabilities = ["read"]
}

path "secret/metadata/myapp/*" {
  capabilities = ["list"]
}

path "database/creds/readonly" {
  capabilities = ["read"]
}

# explicit deny wins over any grant, anywhere
path "secret/data/myapp/admin" {
  capabilities = ["deny"]
}
```

```bash
vault policy write myapp ./myapp-policy.hcl
vault policy read myapp
vault policy list
```

Capabilities: `create`, `read`, `update`, `delete`, `list`, `patch`, `sudo`, `deny`.

`list` is separate from `read` — a token can read a known path without being able to
enumerate the directory, which is often what you want.

Templated policies let one policy serve many identities:

```hcl
path "secret/data/{{identity.entity.name}}/*" {
  capabilities = ["create", "read", "update", "delete"]
}
```

Check before shipping:

```bash
vault token capabilities <token> secret/data/myapp/db
```

## Auth methods

```bash
vault auth list
vault auth enable approle
vault auth enable kubernetes
vault auth enable oidc
```

### AppRole — for machines outside Kubernetes

```bash
vault write auth/approle/role/myapp \
  token_policies="myapp" token_ttl=1h token_max_ttl=4h secret_id_ttl=24h

vault read auth/approle/role/myapp/role-id
vault write -f auth/approle/role/myapp/secret-id

vault write auth/approle/login role_id="..." secret_id="..."
```

Two pieces by design: the `role_id` is static and can ship in config, the `secret_id` is
the sensitive half and should be short-lived and delivered separately. Putting both in the
same file recreates the problem Vault is solving.

### OIDC — for humans

Maps your identity provider's groups to Vault policies, so people authenticate with SSO
rather than holding tokens. The correct answer for human access; root tokens should not be
in daily use.

## Tokens, leases and revocation

```bash
vault token create -policy=myapp -ttl=1h
vault token lookup
vault token renew <token>
vault token revoke <token>
```

Everything Vault issues has a **lease**. Revoking a lease on a dynamic credential deletes
the underlying database user — Vault's cleanup is real, not bookkeeping:

```bash
vault list sys/leases/lookup/database/creds/readonly
vault lease revoke -prefix database/creds/readonly     # kills every one of them
```

That prefix revoke is the incident-response tool: one command invalidates every credential
issued from a role.

**Renewal is the client's job.** A token not renewed before its TTL expires is dead, and
the app sees authentication failures that look like a Vault outage. This is why
`vault agent` exists rather than applications calling the API directly.

Root tokens have no TTL and unlimited power. Generate one when needed with the unseal
shares (`vault operator generate-root`) and revoke it afterwards:

```bash
vault token revoke <root-token>
```

## Vault Agent

A sidecar or host daemon that authenticates, renews, and writes secrets to a file or
environment — so the application reads a file and knows nothing about Vault:

```hcl
auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/etc/vault/role-id"
      secret_id_file_path = "/etc/vault/secret-id"
    }
  }
  sink "file" { config = { path = "/run/vault/token" } }
}

template {
  source      = "/etc/vault/db.ctmpl"
  destination = "/run/secrets/db.env"
  command     = "systemctl reload myapp"
}
```

```
# db.ctmpl
{{- with secret "database/creds/readonly" }}
DB_USER={{ .Data.username }}
DB_PASS={{ .Data.password }}
{{- end }}
```

The agent handles renewal and re-renders when credentials rotate. That `command` is what
makes dynamic credentials practical for apps that read config once at startup.

## Audit

Off by default. Enable it before you need it:

```bash
vault audit enable file file_path=/vault/logs/audit.log
vault audit list
```

Every request and response is logged with hashed secret values. Note that **Vault refuses
to operate if all audit devices fail to write** — a full disk on the audit volume takes
Vault down, by design. Monitor that volume.

## Production notes

- **Storage backend**: Integrated Storage (Raft) is the default now; three or five nodes
  for HA. Consul is legacy for this purpose.
- **Backups**: `vault operator raft snapshot save backup.snap`. The snapshot is encrypted
  with the master key, so it is useless without the unseal shares — store them separately
  and make sure *both* survive. A snapshot alone is not a recoverable backup.
- **TLS**: terminate TLS on Vault itself, not only at a proxy. Tokens in flight are
  bearer credentials.
- **`mlock`**: Vault locks memory to avoid swapping secrets to disk. In containers this
  needs `IPC_LOCK`, or set `disable_mlock = true` and ensure swap is off.
- **Never use the root token for applications.** Policies and auth methods exist so that
  no long-lived all-powerful credential is in play.

## Quick reference

```bash
export VAULT_ADDR='https://vault.example.internal:8200'
vault login -method=oidc
vault status
vault secrets list -detailed
vault auth list
vault policy list
vault kv list secret/
vault token capabilities secret/data/myapp/db
vault lease revoke -prefix database/creds/
```

## Related

- [vault-kubernetes.md](vault-kubernetes.md) — Kubernetes auth, injector, CSI, ESO
- [secrets-management-patterns.md](secrets-management-patterns.md) — choosing an approach
- [../Container Orchestration/kubernetes/kubernetes-rbac-and-security.md](../Container%20Orchestration/kubernetes/kubernetes-rbac-and-security.md)
