# nginx

https://nginx.org/en/docs/

A web server that is also the default answer for static reverse proxying. Config is
explicit and file-based — nothing is discovered, which is both the cost and the
appeal.

## Config layout

```
/etc/nginx/nginx.conf           main config; http {} block
/etc/nginx/conf.d/*.conf        included by default
/etc/nginx/sites-available/     Debian convention: all sites
/etc/nginx/sites-enabled/       symlinks to the active ones
```

On Debian/Ubuntu you write into `sites-available` and symlink into `sites-enabled`.
On RHEL/Fedora there is no such split — drop files in `conf.d/`.

## Minimal reverse proxy

```nginx
server {
    listen 80;
    server_name app.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name app.example.com;

    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Those four `proxy_set_header` lines are not optional in practice. nginx does not
forward them by default, and without them the backend sees every request as coming
from nginx over plain HTTP — which breaks redirect generation, logging, and any
framework that checks whether the request was secure.

## WebSockets

A proxied app that loads but whose live updates never arrive is almost always this:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

`proxy_http_version 1.1` is required — the default 1.0 cannot carry an upgrade.

## The trailing-slash rule

```nginx
proxy_pass http://backend;        # appends the original URI
proxy_pass http://backend/;       # REPLACES the matched location prefix
```

With `location /api/`, a request for `/api/users` becomes `/api/users` in the first
form and `/users` in the second. Getting this backwards produces 404s from the
backend while nginx looks fine.

## Reloading

```bash
sudo nginx -t                 # test config. Always, before reloading.
sudo systemctl reload nginx   # graceful: finishes in-flight requests
sudo systemctl restart nginx  # drops connections
```

`nginx -t` parses the whole config and reports the file and line. A reload with a
broken config leaves the old one running, so catching it here is the difference
between a non-event and an outage.

## Common blocks

```nginx
client_max_body_size 100M;          # default 1M — the usual cause of 413 on upload

proxy_read_timeout 300s;            # long-running requests

gzip on;
gzip_types text/plain text/css application/json application/javascript;

# Upstream group with health-checked failover
upstream app {
    server 10.0.0.11:8080;
    server 10.0.0.12:8080 backup;
}
```

## Serving static files

```nginx
server {
    listen 80;
    server_name static.example.com;
    root /var/www/static;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

`try_files $uri $uri/ /index.html;` instead is the single-page-app form — it hands
unknown paths to the client-side router rather than 404ing.

## Debugging

```bash
sudo tail -f /var/log/nginx/error.log
sudo nginx -T | less                 # full effective config, all includes resolved
```

- **502 Bad Gateway** — backend unreachable or not listening. On RHEL/Fedora also
  check SELinux: `setsebool -P httpd_can_network_connect 1`, which is a very common
  cause of a 502 that makes no other sense.
- **413 Request Entity Too Large** — `client_max_body_size`.
- **Wrong site served** — `server_name` did not match, so nginx used the default
  server. `nginx -T` shows which blocks exist.

## Notes

- nginx needs a reload for every change and templating for dynamic backends. Traefik
  discovers containers instead — see [traefik.md](traefik.md). For a homelab whose
  containers come and go, Traefik is usually less work; nginx is the better fit when
  routing is stable, or when it is also serving files.
