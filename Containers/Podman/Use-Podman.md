# Deploying to Production with Podman: Emphasizing Infrastructure as Code

## Introduction

Podman is a container management tool similar to Docker, but it doesn't require a daemon process and runs containers rootless by default, making it more secure. RHEL has adopted Podman as its native container engine and no longer ships Docker.

Docker commands can be reused, but not automatically: the `docker` name comes from the optional **`podman-docker`** package, which installs a `/usr/bin/docker` shim script. It is not installed by default, so on a stock host `docker` simply does not exist. Install it if you want the alias:

```bash
sudo dnf install podman-docker
```

In production deployments, manual `podman run` commands become unsustainable. Podman offers Quadlet – a declarative IaC solution using systemd unit files – for managing containers, storage, networks, and pods as version-controlled code. This ensures reproducibility, scalability, and auditability.

## Pre-requisites

Setup rootless podman. See `Configure Rootless Podman` article

## Security Best Practices

Podman leverages user namespaces to isolate container UIDs/GIDs from the host. This setup is accomplished by setting up rootless podman in the pre-requisite section.

Podman can be used in conjunction with SELinux (for RHEL-based systems) to enforce mandatory access control. One thing we do is label volumes and files correctly (e.g. using :Z or :z volume mount options) to maintain SELinux context.

Minimal container images should be utilized to reduce the attack surface. Additionally, packages inside the container should be limited to only what is needed.

### Hardening a Quadlet container

Defaults worth applying to anything long-running. Each of these is a Quadlet key:

```ini
[Container]
Image=docker.io/library/nginx:latest

# Drop every capability, then add back only what the process needs
DropCapability=all
AddCapability=NET_BIND_SERVICE

# No privilege escalation via setuid binaries
NoNewPrivileges=true

# Root filesystem read-only; give writable paths explicitly
ReadOnly=true
Tmpfs=/tmp
Tmpfs=/var/run

# Run as a non-root UID inside the container
User=1000
Group=1000

# Pin by digest so the tag cannot move underneath you
# Image=docker.io/library/nginx@sha256:...
```

`ReadOnly=true` is the one that most often surfaces a hidden assumption — an image
that writes to a path you did not expect fails immediately, which is the point.

### Bind mounts and user namespaces

A rootless container's UID 1000 is not your UID 1000; it maps to a subordinate UID on
the host. So a bind-mounted directory you own may be unwritable inside the container.
Two ways out:

```ini
# Map the calling user straight through, so host ownership matches
UserNS=keep-id
```

or fix ownership from inside the namespace:

```bash
podman unshare chown -R 1000:1000 /path/on/host
```

Plain `chown 1000:1000` from the host sets the wrong owner for the container.

### Keeping images current

```ini
AutoUpdate=registry
```

```bash
systemctl --user enable --now podman-auto-update.timer
```

`podman auto-update` replaces the container if the registry has a newer digest for
the tag, and rolls back automatically if the new image fails to start. Check what it
would do first:

```bash
podman auto-update --dry-run
```

Note this is a plain systemd timer, not a generated unit, so `enable` works here —
unlike the Quadlet services themselves.

## Podman Run: A Starting Point

The typical podman run command may look like:

```
podman run -d \
    --name my-webapp \
    -p 8080:80 \
    -v /data/app:/var/www:Z \
    --env "DB_HOST=db" \
    --restart=always \
    docker.io/library/nginx:latest
```
Key Parameters:
- -d : Run in detached mode
- --name : Container identifier
- -p : Host-to-container port mapping (host_port:container_port)
- -v : Volume mount (host_path:container_path:options)
- --env : Environment variables
- --restart : Restart policy

And finally it finishes with the container image, in this case nginx with the latest tag.

Limitations:
- Ephemeral Configuration: Commands aren't version controlled or reusable
- No Self-Healing: Requires external tools for process supervision
- Scalability Challenges: Orchestrating multi-container apps is manual
- Tedious and Clunky: Keeping track of parameters is clunky at best

## Quadlets

Quadlet is a tool designed to simplify the process of running Podman containers under systemd. It allows containers to run in a declarative manner, making it easier to manage and maintain systemd unit files for containerized services.

Quadlets benefits are:
- Declarative Configuration: Defined in .container files
- Systemd Integration: Auto-restart, resource limits, and logging
- Dependency Management: Order containers, networks, and volumes
- Git-friendly: Store configurations as code in repositories

Furthermore, Quadlets are defined in files that can be stored in git thus allowing us to practice `GitOps` and `Infrastructure as Code`. See the Storing Quadlet Files section.

### Quadlet Setup

Quadlet files are systemd unit drop-ins that define containers, pods, networks, and volumes as code. The location of these files determines whether the configuration applies system-wide or just to a single user.

#### Rootless containers (User-Specific)

For rootless containers, we need to add the quadlet files to the users home directory. This should be our default methodology to deploying containers as it is more secure. The downside to this approach is that troubleshooting requires the agent to login as the service account running the container(s).

`mkdir -p ~/.config/containers/systemd/`

Example:
```
~/.config/containers/systemd/webapp.container
~/.config/containers/systemd/my-network.network
~/.config/containers/systemd/my-volume.volume
```

#### Rootful (System-wide)

Rootful containers should be avoided unless absolutely necessary. If needed, the quadlet files should be found at `/etc/containers/systemd`

### Quadlet Example

In this example we will be deploying a web application (just nginx) and a database in a pod. Typically nginx doesn't need a database but to help us understand how containers work together, we are using a database for this example. 

#### Define Quadlet Files
##### Web App
Container definition found at ~/.config/containers/systemd/webapp.container
```
[Unit]  
Description=WebApp Service
After=db.service
Requires=db.service

[Container]  
Image=docker.io/library/nginx:latest  
Volume=app-data.volume:/var/www:Z  
Environment=DB_HOST=db  
# PublishPort is not set here: the container is in a pod, so ports belong to the pod
AutoUpdate=registry
Network=app-network.network
Pod=app-pod.pod

[Service]  
Restart=always  
RestartSec=30  
```
Network definition found at ~/.config/containers/systemd/app-network.network
```
[Network]
Driver=bridge
Subnet=10.89.0.0/24
```

Podman's own default bridge is `10.88.0.0/16`, so a `10.88.0.0/24` here overlaps it.
Pick a range outside it.

Volume definition found at ~/.config/containers/systemd/app-data.volume
```ini
[Volume]
Driver=local
Device=%h/volumes/app-data
Options=bind
User=1000:1000
```

`Options=` without `Device=` is rejected outright — the generator reports *"key Options can't be used without Device"* and produces no unit.

Pod definition found at ~/.config/containers/systemd/app-pod.pod
```ini
[Pod]
PodName=full-stack-pod
PublishPort=8080:80
Network=app-network.network
```

`Name=` is not a `[Pod]` key — it must be `PodName=`, or the pod unit is never generated.

##### Database
Volume definition found at: ~/.config/containers/systemd/db-data.volume
```ini
[Volume]
Driver=local
Device=%h/volumes/db-data
Options=bind
User=1000:1000
```
Container definition found at: ~/.config/containers/systemd/db.container
```
[Unit]
Description=PostgreSQL Database Service

[Container]
Image=docker.io/library/postgres:16
Volume=db-data.volume:/var/lib/postgresql/data:Z
Environment=POSTGRES_USER=webapp
Environment=POSTGRES_PASSWORD=strongpassword
Environment=POSTGRES_DB=webappdb
ContainerName=db
Pod=app-pod.pod

[Service]
Restart=always
RestartSec=30
```
Note: We have put secrets directly into a quadlet file which is a bad practice. We have this here for illustrative purposes only. Better practices can be found below. 

#### Deploy Quadlet

Add `[Install] WantedBy=default.target` to each Quadlet file, then:

```bash
systemctl --user daemon-reload
systemctl --user start db.service
systemctl --user start webapp.service
```

**Do not try to `enable` these.** Quadlet units are produced by a systemd generator
at runtime, so there is no file to symlink and the command always fails:

```console
$ systemctl --user enable --now db.service
Failed to enable unit: Unit /run/user/1000/systemd/generator/db.service is transient or generated
```

Start-at-boot comes from `[Install] WantedBy=default.target` in the Quadlet file,
plus `loginctl enable-linger $USER` so user units survive logout.

Verify deployment:
```
systemctl --user status db.service
systemctl --user status webapp.service
podman ps --filter "name=db"
podman ps --filter "name=webapp"  
```

## Storing Quadlet Files

Quadlet files should be stored in a git repository. This allows containers to be deployed, configured, updated, and maintained via Infrastructure as Code and Configuration as Code utilizing tooling such as CI/CD pipelines and Ansible.

The idea is that containers should not be acted upon using the CLI but should have robust CI/CD pipelines that can deploy, configure, update, and maintain the containers. This enables us to utilize a `GitOps` approach that prepares the way for more advanced technologies such as `kubernetes`

## Logging and Monitoring

Effective logging and monitoring are essential for troubleshooting, maintaining, and scaling production container deployments.

### Accessing Logs
Container logs:

`podman logs <container>`

Pod logs:

`podman pod logs <pod name>`

### Log rotation
Prevent disk overuse by configuring log rotation. Add to the container file.

Example:
~/.config/containers/systemd/webapp.container
```
[Container]
Image=docker.io/library/nginx:latest
LogOpt=max-size=10m
LogOpt=max-file=3
```

### Send logs to an ELK Stack

Podman doesn't have a native "logstash" driver but can utilize the syslog driver to send logs to an ELK stack.

The Logstash server will need a TCP input setup in order to receive the logs.

Example:
```
[Unit]
Description=WebApp Service

[Container]
Image=docker.io/library/nginx:latest
Volume=app-data.volume:/var/www:Z
Environment=DB_HOST=db
Pod=app-pod.pod

# ELK Logging Configuration
LogDriver=syslog
LogOpt=syslog-address=tcp://logstash-host:5140
LogOpt=tag=webapp
LogOpt=syslog-format=rfc5424

[Service]
Restart=always
RestartSec=30
```

Alternatively, journald can be used to forwards logs to logstash as well.

## Backup and Restore Strategies

Because our focus is on Infrastructure as Code (IaC), all quadlet files should be found in git. This makes deploying, re-deploying, and recovering containers quick and simple. 

Podman offers the ability to use `Named Volumes` and `Bind Mounts`.

`Bind Mounts` allow you to bind a file or directory inside of a container to a file or directory on the host. By using this approach, we can utilize our current backup tooling to backup important container files and folders. Note that not all containers are necessary to be mounted to the host. Typically only configuration, settings, files that must persist are bind mounted to the host.

### Databases

Should we choose to utilize podman for databases, database containers can be backed up utilizing the same tooling and strategies that are used for non-container databases such e.g. pg_dump.

Example:

`podman exec <db_container> pg_dump -U <user> <db> > db_backup.sql`

## Secrets Management

Best practice dictates that secrets should not be stored in plaintext in podman run commands or in quadlet files. Injecting secrets in container images is also a bad practice.

### Podman secrets

Podman natively supports secrets through Podman secrets.

Two things to be clear about, both verified against Podman 5.8:

- **They are not encrypted.** The default driver is `file`, which stores the value
  base64-encoded under `~/.local/share/containers/storage/secrets/`. Anyone who can
  read that directory can `base64 -d` it. The directory is mode `0700`, so this is
  better than a password committed to git, but it is not encryption at rest. For
  actual encryption use the `pass` or `shell` driver, or an external manager.
- **There is no `podman secret rotate`.** The subcommands are `create`, `exists`,
  `inspect`, `ls` and `rm`. To change a secret you remove and recreate it, then
  restart the consuming containers — `podman secret rm` refuses while a container is
  using it, so stop the unit first.

Example:

```
# Create secret from file
vim db_pass.txt
# Add your secret, save, and exit
podman secret create db_password db_pass.txt
rm db_pass.txt  # Remove source file immediately

# Use in Quadlet file
[Container]
Image=docker.io/library/postgres:16

# Inject as an env var
Secret=db_password,type=env,target=POSTGRES_PASSWORD

# OR mount as a file — preferred, since env vars show up in podman inspect
# and in the process environment of anything in that container
Secret=db_password,type=mount,target=/run/secrets/db_password
```

Note the comments are on their own lines. systemd has no inline comments: putting
`# Inject as env var` after the value makes it part of the value.

### External Secrets Managers

External secret managers such as Hashicorp Vault or AWS Secrets Manager also provide means to protect secrets. This documentation does not detail how to use those offerings until or unless they are selected for this use case. 

## Use Kubernetes YAML with Quadlets

Quadlet supports Kubernetes (k8s) YAML files through .kube unit files, enabling you to deploy Kubernetes-native definitions while leveraging Podman's rootless capabilities and systemd integration. This approach bridges Kubernetes workflows with Podman's operational simplicity.

### How to Use .kube files with Quadlet

Create a .kube file referencing your k8s YAML:  ~/.config/containers/systemd/myapp.kube
```
[Unit]
Description=My Kubernetes App

[Kube]
Yaml=deployment.yaml
Network=app-network.network
PublishPort=8080:80

[Install]
WantedBy=default.target
```

See https://www.redhat.com/en/blog/multi-container-application-podman-quadlet for more guidance

## Docker to Podman

More comfortable with docker and docker compose? Podman ships `podman compose`, a
thin wrapper that hands the file to an external provider — `docker-compose` if
installed, otherwise `podman-compose`. It is not a reimplementation, so behaviour
depends on which provider is present:

```bash
podman compose up -d          # delegates to the provider
podman compose version        # shows which provider was picked
```

For production, convert to Quadlet instead so systemd owns the lifecycle. `podlet`
generates Quadlet files from a compose file, a `podman run` command, or an existing
container:

```bash
podlet compose docker-compose.yml
podlet podman run -d --name web -p 8080:80 docker.io/library/nginx
```

See https://github.com/containers/podlet

## Scaling and Orchestration Beyond Pods

While Podman is great for development and for small to medium deployments, it runs into limitations for large-scale production environments. 

Kubernetes should be considered when you need:
- Auto-scaling based on load
- Built-in load balancing with automated traffic distribution
- Multi-host networking
- Comprehensive service discovery
- Self-healing of pods and containers
- High availability
- Zero downtime deployments and updates

## Useful Commands

| Command | Description |
| ----------- | ----------- |
| podman image ls | List all images available to the user |
| podman pull <image> | Download an image from a registry |
| podman ps -a | List all containers, including stopped ones |
| podman run [options] <image> | Run a new container from an image |
| podman start <container> | Start an existing (stopped) container |
| podman stop <container> | Stop a running container |
| podman restart <container> | Restart a container |
| podman rm <container> | Remove a stopped container. Use -f to force remove running containers |
| podman rmi <image> | Remove an image from local storage |
| podman logs <container> | View logs for a container |
| podman top <container> | Show running processes inside a container |
| podman exec -it <container> <command> | Run a command inside a running container (e.g. bash) |
| podman inspect <container or image> | Show detailed metadata and configuration |
| podman port <container> | List port mappings for a container |
| podman network ls | List available networks |
| podman network inspect <network> | Inspect network details |
| podman pod ls | List pods |
| podman pod create | Create a pod |
| podman system prune -a | Remove unused containers, images, and networks. Add --volumes to include volumes, which it otherwise keeps. |

### Advanced (Rootful Only)
| Command | Description |
| ----------- | ----------- |
| sudo podman container checkpoint <container> | Save the state of a running container (rootful only) |
| sudo podman container restore <container> | Restore a container from a checkpoint (rootful only) |
| sudo podman container checkpoint <container> -e /tmp/checkpoint.tar.gz | Export a checkpoint for migration (rootful only) |
| sudo podman container restore -i /tmp/checkpoint.tar.gz | Restore a container from an exported checkpoint (rootful only) |

### Tips
- For most day-to-day tasks, you do not need sudo unless working with checkpoint/restore or managing containers as root.
- Use container ID or name as required by each command.

## Troubleshooting Tips

- Check logs
    - `podman logs -f <container>`
    - -f follows the logs
- Inspect the container or pod
    - `podman inspect <container name or pod name>`
- Review systemd service logs
    - `journalctl --user -u <service_name>.service -f`
- `podman machine` is only relevant on macOS and Windows, where containers run
  inside a VM. On a Linux host there is no machine and `podman machine list` is
  empty — that is normal, not a fault.

## Useful Links
- https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes
- https://www.reddit.com/r/podman/comments/1bmkv1q/rootless_containers/
- https://docs.podman.io/en/stable/Commands.html
- https://mpolinowski.github.io/docs/DevOps/Linux/2019-09-25--podman-cheat-sheet/2019-09-25/
- https://www.redhat.com/en/blog/podman-features-2
- https://developers.redhat.com/blog/2020/09/25/rootless-containers-with-podman-the-basics