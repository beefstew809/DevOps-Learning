# DNS and TLS Operations

The two systems that cause the most preventable outages, because both fail on a timer.

## DNS as infrastructure

### Zone design

```
example.com              apex — A/AAAA or ALIAS, never CNAME
www.example.com          CNAME → example.com, or its own A
app.example.com          the service
*.dev.example.com        wildcard for ephemeral environments
example.internal         split-horizon: private zone, private answers
```

A separate **internal zone** is worth setting up early. Resolving internal hostnames to private
addresses means no internal traffic depends on public DNS, and nothing internal is discoverable
by scanning your public zone.

### The records that are really security configuration

```
example.com.  TXT  "v=spf1 include:_spf.provider.com -all"
_dmarc        TXT  "v=DMARC1; p=reject; rua=mailto:dmarc@example.com"
selector._domainkey TXT "v=DKIM1; k=rsa; p=MIGfMA0..."
example.com.  CAA  0 issue "letsencrypt.org"
```

- **SPF** — which hosts may send mail as you. `-all` (hard fail) rather than `~all` once you are
  confident. Note SPF has a **10-DNS-lookup limit** including nested `include:` — exceeding it
  makes SPF fail entirely, silently.
- **DMARC** — what to do with failures. Start `p=none` with reporting, read the reports, then
  move to `quarantine` and `reject`.
- **CAA** — which CAs may issue for your domain. Cheap, and it blocks mis-issuance by any other
  CA.

Even if you do not send mail, publish an SPF of `v=spf1 -all` and a DMARC of `p=reject` for the
domain. It stops your domain being used in spoofed mail.

### Operational rules

**Lower TTL before changes, not during.** Drop to 60s at least one full TTL ahead of a planned
migration, cut over, then restore. Otherwise you wait out the old TTL with traffic split.

**Never point at an IP you do not control.** A dangling CNAME or A record to a released cloud
address is **subdomain takeover** — someone else claims that address or bucket name and serves
content from your hostname, with a valid certificate they obtained themselves. Audit for
dangling records:

```bash
# every name in a zone, resolved
for n in $(dig +short NS example.com); do echo "--- $n"; done
dig AXFR example.com @ns1.example.com 2>/dev/null | awk '{print $1, $4, $5}'
```

Unused records are not harmless. Delete them.

**Registrar and DNS hosting are separate.** Lock the registrar (transfer lock, MFA, separate
credentials from everything else). Domain hijacking at the registrar bypasses every other
control you have.

```bash
dig SOA example.com +short              # serial should change when you edit the zone
dig NS example.com +short               # delegation matches the registrar?
dig +trace app.example.com              # where resolution actually goes
```

A zone edited at the provider but with an unchanged SOA serial, or NS records that disagree with
the registrar, explains "my change did nothing".

## TLS

### What the handshake establishes

Three things, and distinguishing them matters when one fails:

1. **Identity** — the certificate proves the server controls the name.
2. **Key agreement** — an ephemeral shared key (forward secrecy).
3. **Negotiation** — protocol version, cipher, ALPN (HTTP/2 vs HTTP/1.1).

TLS 1.3 is the target; 1.2 is acceptable. **1.0 and 1.1 are dead** and should be disabled.
Default configurations in older proxies still enable them, which is why
[../reverse_proxy/traefik.md](../reverse_proxy/traefik.md) recommends setting `tls-opts`
explicitly.

### The chain

```
Root CA (in the client's trust store)
  └─ Intermediate CA
       └─ Your certificate (leaf)
```

**The server must send the leaf and the intermediates, not just the leaf.** Clients have roots,
not intermediates. Omitting the chain is the classic misconfiguration, and it fails
asymmetrically:

- Browsers often succeed — they cache intermediates from other sites and may fetch them.
- `curl`, Java, Go, Python and every application HTTP client fail.

So "works in my browser, fails from the app" is nearly always a missing intermediate.

```bash
openssl s_client -connect example.com:443 -servername example.com -showcerts </dev/null \
  2>/dev/null | grep -c 'BEGIN CERTIFICATE'
```

Expect 2 or 3. A result of 1 is the bug. Serve `fullchain.pem`, never `cert.pem`.

### Diagnosing

```bash
# full picture
openssl s_client -connect example.com:443 -servername example.com </dev/null

# dates and names
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -dates -subject -ext subjectAltName

# verify a local chain without a server
openssl verify -untrusted chain.pem cert.pem

# does the key match the certificate?
openssl x509 -noout -modulus -in cert.pem | openssl sha256
openssl rsa  -noout -modulus -in key.pem  | openssl sha256     # must match

# force a protocol version
openssl s_client -connect example.com:443 -tls1_2
```

**`-servername` is mandatory** for any host serving multiple certificates. Without SNI you get
the default certificate and a confusing name mismatch.

The modulus comparison is the check for "key values mismatch" errors on startup — a leaf and
key from different issuances.

**Validity is checked against the client's clock.** A host with skewed time rejects perfectly
valid certificates; a container without the `ca-certificates` package trusts nothing. Both
present as certificate errors with nothing wrong on the server.

| Error | Cause |
| --- | --- |
| `unable to get local issuer certificate` | Missing intermediate (server) or missing trust store (client) |
| `certificate has expired` | Renewal failed |
| `Hostname mismatch` | Name not in SAN. The `CN` field is ignored by modern clients |
| `self signed certificate in certificate chain` | Private CA not trusted |
| `tlsv1 alert protocol version` | Client and server share no version |
| `key values mismatch` | Cert and key are from different pairs |

Note the CN row: **modern clients only check `subjectAltName`**. A certificate with the name
only in CN fails everywhere, which catches people generating certs by hand.

### ACME and automation

Let's Encrypt certificates last 90 days, so renewal must be automatic. Two challenge types:

| Challenge | Requires | Use when |
| --- | --- | --- |
| **HTTP-01** | Inbound port 80 from the internet | Public web server |
| **DNS-01** | API access to your DNS provider | **Private services, wildcards** |

DNS-01 is the one that matters for a homelab: it needs no inbound connectivity at all, so
internal services behind a tunnel or on a tailnet can still hold public certificates. It is also
the only way to get a wildcard.

In Kubernetes, cert-manager:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-token
              key: api-token
```

```bash
kubectl get certificate -A
kubectl describe certificate web-tls
kubectl get certificaterequest,order,challenge -A     # the chain of objects, in order
```

When a certificate stays `False`, walk **Certificate → CertificateRequest → Order → Challenge**.
The Challenge's events name the actual failure — usually a DNS propagation timeout or an API
token lacking edit permission on the zone.

**Use the staging endpoint while iterating.** Let's Encrypt's production rate limits (50
certificates per registered domain per week, 5 duplicate certificates per week) are easy to hit
with a misconfigured loop, and then you are blocked for days.

### Renewal is the failure mode

Certificates do not break; **renewal breaks and nobody notices for 90 days.** Defences:

1. **Alert on expiry**, 14 days out, from outside the system:
   ```promql
   probe_ssl_earliest_cert_expiry - time() < 14*86400
   ```
2. **Alert on the renewal mechanism**, not just the date — a cert-manager Certificate in a
   `False` state, or a failed `certbot` timer.
3. **Check the served certificate**, not the file on disk. A renewed file that the proxy never
   reloaded is still serving the old one.

That third point is the subtle one: renewal succeeded, the file is new, and the process is
holding the old certificate in memory. Always reload after renewal (`--deploy-hook`), and verify
over the wire:

```bash
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -enddate
```

### Internal PKI

For internal services, public certificates are not required and a private CA is often cleaner —
short-lived certs, no rate limits, no public record of internal hostnames in certificate
transparency logs.

Options: Vault's PKI engine (see
[../Secrets Management/vault-basics.md](../Secrets%20Management/vault-basics.md)), `step-ca`, or
cert-manager's CA issuer. The cost is distributing the root to every client's trust store,
which is the part that makes people reach for public certificates instead.

Certificate Transparency is worth knowing about in this context: every publicly issued
certificate is logged publicly, so `crt.sh` lists your internal hostnames if you used a public
CA for them. That is an information leak some people care about.

## Checklist

**DNS**

- Registrar locked, MFA, credentials separate from everything else
- SPF, DKIM, DMARC published — even for non-mail domains
- CAA restricting issuance
- Internal zone for internal names
- No dangling records pointing at released resources
- TTLs lowered ahead of planned changes

**TLS**

- TLS 1.2 minimum, 1.3 preferred, 1.0/1.1 disabled
- Full chain served — verify the certificate count over the wire
- Automated renewal, with a reload hook
- Expiry alert from outside, 14 days
- Renewal-mechanism alert, not just expiry
- SANs correct; do not rely on CN

## Related

- [networking-fundamentals.md](networking-fundamentals.md)
- [../reverse_proxy/traefik.md](../reverse_proxy/traefik.md) — ACME, DNS challenge, tls-opts
- [../Observability/logging-and-alerting.md](../Observability/logging-and-alerting.md) — blackbox probes
- [../Secrets Management/vault-basics.md](../Secrets%20Management/vault-basics.md) — PKI engine
