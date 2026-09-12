# Traefik

https://doc.traefik.io/traefik/

A reverse proxy that discovers its own configuration. Instead of editing a config
file per site, Traefik watches a *provider* — usually the Docker socket — and builds
routes from container labels as containers come and go.

Working compose stack and rule files: [../Containers/docker/traefik](../Containers/docker/traefik)

## The four objects

Requests flow through these in order:

```
EntryPoint  ->  Router  ->  Middleware(s)  ->  Service
  :443          host rule     auth, headers     container:port
```

- **EntryPoint** — a port Traefik listens on (`web` :80, `websecure` :443).
- **Router** — a rule matching requests (`Host(...)`, `PathPrefix(...)`) and the
  service to send them to.
- **Middleware** — something applied in between: auth, redirect, compression, rate
  limiting, headers.
- **Service** — the backend. With the Docker provider this is usually inferred.

## Static vs dynamic configuration

The distinction behind most Traefik confusion:

| | Static | Dynamic |
| --- | --- | --- |
| Contains | entrypoints, providers, certificate resolvers | routers, middlewares, services |
| Lives in | `traefik.yml`, CLI flags, env | container labels, files in `rules/` |
| On change | **requires a restart** | picked up live |

So a new entrypoint or a new ACME resolver means restarting Traefik. A new route or
middleware does not.

## Routing a container with labels

```yaml
services:
  myapp:
    image: myapp:latest
    networks: [proxy]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`app.example.com`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"
```

Two things that trip people up:

- **`loadbalancer.server.port` is the port inside the container**, not a published
  port. Traefik reaches the container over the shared Docker network, so the app does
  not need `ports:` published at all — and usually should not be.
- **Traefik and the app must share a network.** If they do not, the router appears in
  the dashboard and every request returns a gateway error.

## File provider and reusable middleware

Middleware defined in labels is scoped to that container. Anything shared belongs in
the file provider — which is what `rules/` in this repo is for:

```yaml
# rules/middlewares-secure-headers.yml
http:
  middlewares:
    secure-headers:
      headers:
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        stsSeconds: 31536000
```

Then reference it by name, suffixed with the provider:

```yaml
- "traefik.http.routers.myapp.middlewares=secure-headers@file"
```

The `@file` matters. A middleware from the file provider referenced without it is
looked up in the Docker provider and not found.

**Chains** group several middlewares so a router applies one name — that is what the
`chain-*.yml` files here do (`chain-no-auth`, `chain-basic-auth`,
`chain-authentik-proxy-auth`). Switching a route from public to
authenticated-behind-Authentik becomes a one-label change.

## TLS

`acme.json` stores the ACME account key and every issued certificate's private key.
It must be mode `600` or Traefik refuses to use it:

```bash
touch acme.json && chmod 600 acme.json
```

It is gitignored — see [../Containers/docker/traefik/acme/README.md](../Containers/docker/traefik/acme/README.md).

Use the **DNS challenge** for anything not publicly reachable, or for a wildcard
certificate. The HTTP challenge needs inbound :80 from the internet, which a homelab
service behind a tunnel usually does not have.

`tls-opts.yml` here sets the minimum TLS version and cipher suites — worth keeping,
since Traefik's defaults permit older versions than you probably want.

## Debugging

```bash
docker logs -f traefik
```

- **404 on a route you just added** — the router did not match. Check the rule, and
  that `traefik.enable=true` is set.
- **502 / gateway error** — the router matched but the backend is unreachable: wrong
  `server.port`, or Traefik and the app are not on a shared network.
- **Certificate is self-signed (`TRAEFIK DEFAULT CERT`)** — ACME has not issued yet.
  Check the logs for the challenge failing, and that the resolver name in the label
  matches one defined in the static config.

Enable the dashboard while debugging; it shows which routers and middlewares Traefik
actually loaded, which is faster than inferring from behaviour. Do not leave it
exposed without auth.

## Notes

- Traefik is bundled with k3s and serves its Ingress resources. If you run your own
  Traefik, install k3s with `--disable=traefik` — see
  [../Container Orchestration/k3s/k3s-Basics.md](../Container%20Orchestration/k3s/k3s-Basics.md).
- Compared with nginx: Traefik wins where backends change often, because nothing has
  to be re-templated. nginx wins on static routing, fine-grained control, and as a
  web server in its own right — see [nginx.md](nginx.md).
