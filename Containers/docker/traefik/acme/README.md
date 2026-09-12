# acme/

Traefik writes `acme.json` here — the ACME account key plus the private key of
every certificate it issues. It is gitignored on purpose.

Traefik creates the file itself on first start. It must be mode `600` or Traefik
refuses to use it:

```sh
touch acme.json
chmod 600 acme.json
```

If you ever committed a populated `acme.json`, treat every key in it as disclosed:
revoke the certificates and let Traefik re-issue.
