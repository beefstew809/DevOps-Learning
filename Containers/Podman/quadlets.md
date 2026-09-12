# Quadlets

Quadlets manage Podman containers with Systemd by creating unit files for the containers

It is declarative similar to Docker Compose. 

Resource:
- https://github.com/dwedia/podmanQuadlets
- https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html

## Setup

Create the directories:

`mkdir -p ~/.config/containers/systemd/`

Create or modify a .container file:

`nano ~/.config/containers/systemd/myapp.container`

Reload systemd:

`systemctl --user daemon-reload`

Create any peristent storage needed:

`mkdir -p /path/to/storage/containerfolder`

Start the container:

`systemctl --user start myapp.service`

Resource: https://blog.nerdon.eu/podman-quadlet-getting-started/

## Three rules to internalise first

These account for most of the time lost to Quadlet.

### 1. The unit name is not the file name

A systemd generator turns each Quadlet file into a `.service`. You always act on the
generated service name, never on the source file name:

| Quadlet file | Generated unit |
| --- | --- |
| `myapp.container` | `myapp.service` |
| `myapp.kube` | `myapp.service` |
| `foo.pod` | `foo-pod.service` |
| `app.network` | `app-network.service` |
| `data.volume` | `data-volume.service` |

So `systemctl --user start myapp.container` fails — it has to be `myapp.service`.
Note the `.pod` case gains a `-pod` suffix.

### 2. You cannot `systemctl enable` a Quadlet service

The units are generated at runtime, so there is no file for systemd to symlink:

```console
$ systemctl --user enable myapp.service
Failed to enable unit: Unit /run/user/1000/systemd/generator/myapp.service is transient or generated
```

To start a Quadlet at boot, put it in the Quadlet file itself and reload:

```ini
[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user start myapp.service
```

For a rootless (`--user`) unit the target is `default.target`. `multi-user.target`
does not exist in the user manager — use it only for system-wide Quadlets in
`/etc/containers/systemd/`.

Also enable linger, or the units stop when you log out:

```bash
loginctl enable-linger "$USER"
```

### 3. systemd has no inline comments

Only whole-line comments are valid. This silently breaks the value:

```ini
# WRONG — the comment becomes part of the value and systemd cannot parse it
TimeoutStartSec=900 # Systemd standard timeout is 90s, often too little to pull an image

# RIGHT
# Systemd standard timeout is 90s, which can be too little to pull the image.
TimeoutStartSec=900
```

Quadlet does not catch this — it copies the line verbatim into the generated unit,
where systemd rejects it at load time.

The same applies to values containing spaces, which need quoting:

```ini
# WRONG — generates: --env Angeles --env TZ=America/Los
Environment=TZ=America/Los Angeles

# RIGHT (and the IANA zone name uses an underscore)
Environment=TZ=America/Los_Angeles
```

## Validating before you start anything

Run the generator by hand. It prints every unit it would produce and names the file
and key for anything it rejects:

```bash
# rootless
/usr/libexec/podman/quadlet -dryrun -user

# system-wide
sudo /usr/libexec/podman/quadlet -dryrun
```

Podman 5.6+ also has a `quadlet` subcommand:

```bash
podman quadlet list           # what Quadlets exist and their status
podman quadlet print myapp.container
```

A key Quadlet does not recognise is a **hard failure** — the whole unit is skipped
and no service appears, which looks identical to the file not being read at all:

```
converting "db.container": unsupported key 'Name' in group 'Container'
```

## .container file

```ini
[Unit]
Description=Quick, one line description
# List of targets to start before
# Before=
# List of targets to start after
After=local-fs.target
Wants=network-online.target
After=network-online.target

[Container]
Image=registry.access.redhat.com/ubi9/ubi
ContainerName=TestContainer1
Environment=DATABASE_USER=dbsuer
Timezone=local

Volume=/path/to/storage/containerfolder:/config:rw,Z
PublishPort=8088:8080/tcp

[Service]
# Systemd standard timeout is 90s, which can be too little to pull the image.
TimeoutStartSec=900
Restart=always

[Install]
WantedBy=default.target
```

Note `PublishPort=` — not `Port=`, which Quadlet rejects. And `ContainerName=` —
not `Name=`.

`Network=host` was removed from this example: with host networking the container
shares the host's network stack, so `PublishPort=` has nothing to do and the two
keys contradict each other. Use one or the other.

## Example Application

Source: https://git.mo8it.com/mo8it/main_server/src/commit/14a949bb4f5b08d0666a7161ecfc8942cfa605b9/containers/oxitraffic

### Application
oxitraffic.container
```ini
[Container]
Image=docker.io/mo8it/oxitraffic:latest
AutoUpdate=registry
Network=traefik.network
Network=oxitraffic.network
Volume=%h/volumes/oxitraffic/config.toml:/volumes/config.toml:Z,ro
Volume=%h/volumes/oxitraffic/logs:/var/log/oxitraffic:Z

[Unit]
Requires=oxitraffic-db.service
After=oxitraffic-db.service

[Service]
Restart=always

[Install]
WantedBy=default.target
```
### Database
oxitraffic-db.container
```ini
[Container]
Image=docker.io/library/postgres:16
AutoUpdate=registry
Network=oxitraffic.network
Volume=%h/volumes/oxitraffic/db:/var/lib/postgresql/data:Z

EnvironmentFile=%h/volumes/oxitraffic/.postgres.env
Environment=TZ=America/Los_Angeles
Environment=PGTZ=America/Los_Angeles
# Password belongs in the EnvironmentFile above, or better, a Podman secret:
# Secret=postgres_password,type=env,target=POSTGRES_PASSWORD

[Service]
Restart=always

[Install]
WantedBy=default.target
```

`%h` expands to the user's home directory. Other useful specifiers: `%t` runtime
directory, `%n` unit name.

### Network
oxitraffic.network
```ini
[Network]
```

An empty `[Network]` section is valid — it creates a network with defaults named
after the file.

### Traefik
traefik.container
```ini
[Container]
Image=docker.io/library/traefik:latest
AutoUpdate=registry
Network=traefik.network
PublishPort=8000:80
PublishPort=4430:443
Volume=%h/sync/volumes/traefik:/etc/traefik:Z,ro
Volume=%h/volumes/traefik/logs:/volumes/logs:Z
Volume=%h/volumes/traefik/certs:/volumes/certs:Z

[Service]
Restart=always

[Install]
WantedBy=default.target
```

Rootless containers cannot bind ports below 1024 by default, which is why this maps
80 to 8000. To allow the low ports instead:

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
# persist it
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-rootless-ports.conf
```

traefik.network
```ini
[Network]
```

## Another Example
Source: https://blog.while-true-do.io/podman-quadlets/

This one is **system-wide** — the files go in `/etc/containers/systemd/` and the
commands take no `--user`. That is why `multi-user.target` is correct here.

### Network and Volume files
wordpress.network
```ini
[Unit]
Description=WordPress Container Network

[Network]
Label=app=wordpress
```

wordpress-app.volume
```ini
[Unit]
Description=WordPress Container Volume

[Volume]
Label=app=wordpress
```

wordpress-db.volume
```ini
[Unit]
Description=WordPress Database Container Volume

[Volume]
Label=app=wordpress
```

### Application and Database
wordpress-db.container
```ini
[Unit]
Description=WordPress Database Container

[Container]
Label=app=wordpress
ContainerName=wordpress-db
Image=docker.io/library/mariadb:10
Network=wordpress.network
Volume=wordpress-db.volume:/var/lib/mysql
Environment=MARIADB_RANDOM_ROOT_PASSWORD=1
Environment=MARIADB_USER=wordpress
Environment=MARIADB_DATABASE=wordpress
# This one should be a secret — see the Secrets section
Secret=wordpress_db_password,type=env,target=MARIADB_PASSWORD

[Install]
WantedBy=multi-user.target
```

wordpress-app.container
```ini
[Unit]
Description=Wordpress App Container
Requires=wordpress-db.service
After=wordpress-db.service

[Container]
Label=app=wordpress
ContainerName=wordpress-app
Image=docker.io/library/wordpress:6
Network=wordpress.network
Volume=wordpress-app.volume:/var/www/html
Environment=WORDPRESS_DB_HOST=wordpress-db
Environment=WORDPRESS_DB_USER=wordpress
Environment=WORDPRESS_DB_NAME=wordpress
# This one should be a secret — see the Secrets section
Secret=wordpress_db_password,type=env,target=WORDPRESS_DB_PASSWORD
PublishPort=8080:80

[Install]
WantedBy=multi-user.target
```

### Run it
```bash
sudo systemctl daemon-reload
# See the generated unit
systemctl cat wordpress-app.service

sudo systemctl start wordpress-app.service
```

## Tools

https://github.com/containers/podlet
- Podlet generates Podman Quadlet files from a Podman command, compose file, or existing object

## Secrets

Create the secret, then reference it by name. Keep the two commands separate:

```bash
echo "secretdata" > secretfile
podman secret create secretname secretfile
rm secretfile          # the secret is stored now; delete the source
```

Then in `~/.config/containers/systemd/test-secret.container`:

```ini
[Container]
Image=docker.io/library/debian:12-slim
Secret=secretname,type=env,target=SECRET_ENV
Exec=bash -c 'echo $SECRET_ENV'
```

Start it with `systemctl --user start test-secret.service`, then
`systemctl --user status test-secret.service` shows `secretdata` in the output,
confirming the environment variable was injected.

Mount as a file instead of an env var when the app can read a path — env vars are
visible in `podman inspect` and in the process environment:

```ini
Secret=secretname,type=mount,target=/run/secrets/secretname
```

**Podman secrets are not encrypted** under the default `file` driver — they are
base64-encoded in `~/.local/share/containers/storage/secrets/`. That is better than
a password in a git-tracked unit file, but it is not encryption at rest. For real
encryption use the `pass` or `shell` driver, or an external manager.

## Keeping images current

```ini
[Container]
Image=docker.io/library/nginx:latest
AutoUpdate=registry
```

Then enable the timer once per user:

```bash
systemctl --user enable --now podman-auto-update.timer
```

`AutoUpdate=registry` checks the registry for a newer digest on the same tag.
`AutoUpdate=local` only uses images already pulled. Note that `podman auto-update`
rolls back automatically if the new image fails to start.

`Pull=newer` on the `Image=` line is the other option — it checks for a newer image
every time the unit starts, rather than on a timer.

## Debugging

```bash
# Why did my unit not appear at all?
/usr/libexec/podman/quadlet -dryrun -user

# What did the generator actually produce?
systemctl --user cat myapp.service

# Why did it fail to start?
journalctl --user -u myapp.service -n 50 --no-pager
```

| Symptom | Cause |
| --- | --- |
| `Unit myapp.service not found` | Generator rejected the file — run the dry-run |
| `is transient or generated` | You tried to `enable` it; use `[Install]` instead |
| `unsupported key 'X' in group 'Y'` | Wrong key name; see the table below |
| Unit starts, container exits instantly | Check `Exec=`, and `journalctl` for the container's own output |
| Works until logout | `loginctl enable-linger $USER` |

### Keys that are commonly got wrong

| Wrong | Right | Section |
| --- | --- | --- |
| `Name=` | `ContainerName=` | `[Container]` |
| `Name=` | `PodName=` | `[Pod]` |
| `Port=` | `PublishPort=` | `[Container]`, `[Pod]` |
| `HostPath=`, `MountOptions=` | `Device=`, `Options=` | `[Volume]` |
| `Options=o=bind` alone | also needs `Device=/path` and `Driver=local` | `[Volume]` |

## Template with Options
Source: https://blog.nerdon.eu/podman-quadlet-getting-started/
```ini
[Unit]
# (Optional) A brief description of the service
Description=
# (Optional) Services you want to run with this one
Wants=
# (Optional) Services that need to start before this one
After=

[Container]
# (Mandatory) The container's name
ContainerName=
# (Mandatory) The container image to use (e.g., docker.io/library/alpine)
Image=
# (Optional) Path to an .env file
EnvironmentFile=
# (Optional) Key=value pairs for environment variables. Quote values with spaces.
Environment=
# (Optional) Persistent storage paths (host:container)
Volume=
# (Optional) Custom network for the container
Network=
# (Optional) Ports to publish (host:container)
PublishPort=
# (Optional) Inject a Podman secret
Secret=
# (Optional) Custom command to run in the container
Exec=
# (Optional) Additional Podman arguments, for anything Quadlet has no key for
PodmanArgs=
# (Optional) Extra capabilities to add to the container
AddCapability=
# (Optional) Drop capabilities. DropCapability=all then add back is the safer default.
DropCapability=
# (Optional) Add host devices to the container
AddDevice=
# (Optional) Disable SELinux labels
SecurityLabelDisable=
# (Optional) Run as a specific user inside the container
User=
# (Optional) Map the calling user into the container, so bind mounts stay writable
UserNS=
# (Optional) Autoupdate. Also enable podman-auto-update.timer
AutoUpdate=registry
# (Optional) Add metadata labels to the container
Label=
# (Optional) User ID mapping. Example: 0:10000:10 (Inside:Outside:Range)
UIDMap=
# (Optional) Group ID mapping Example: 0:10000:10 (Inside:Outside:Range)
GIDMap=
# (Optional) Health check command and what to do when it fails
HealthCmd=
HealthOnFailure=

[Service]
# (Optional) Set to 'always' or 'on-failure' to restart on failure
Restart=
# (Optional) Time to wait before considering a failure
TimeoutStartSec=

[Install]
# (Optional) default.target for --user units, multi-user.target for system-wide
WantedBy=
```
