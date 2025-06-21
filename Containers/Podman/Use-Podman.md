# Deploying to Production with Podman: Emphasizing Infrastructure as Code

## Introduction

Podman is a container management tool similar to Docker, but it doesn't require a daemon process and runs containers with rootless capabilities by default, making it more secure. RHEL has adopted Podman as its native container engine, phasing out Docker, and for compatibility purposes, RHEL systems now map the 'docker' command as an alias to 'podman'. This allows you to use familiar Docker commands while actually leveraging Podman's enhanced security model and RHEL integration.

In production deployments, manual `podman run` commands become unsustainable. Podman offers Quadlet – a declarative IaC solution using systemd unit files – for managing containers, storage, networks, and pods as version-controlled code. This ensures reproducibility, scalability, and auditability.

## Pre-requisites

Setup rootless podman. See `Configure Rootless Podman` article

## Security Best Practices

Podman leverages user namespaces to isolate container UIDs/GIDs from the host. This setup is accomplished by setting up rootless podman in the pre-requisite section.

Podman can be used in conjunction with SELinux (for RHEL-based systems) to enforce mandatory access control. One thing we do is label volumes and files correctly (e.g. using :Z or :z volume mount options) to maintain SELinux context.

Minimal container images should be utilized to reduce the attack surface. Additionally, packages inside the container should be limited to only what is needed.

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
# Port=8080:80 # Not needed since container is part of a pod and this is defined in the pod
Label=io.containers.autoupdate=registry
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
Subnet=10.88.0.0/24
```
Volume definition found at ~/.config/containers/systemd/app-data.volume
```
[Volume]  
User=1000:1000  
Options=o=bind  
```
Pod definition found at ~/.config/containers/systemd/app-pod.pod
```
[Pod]  
Name=full-stack-pod  
PublishPort=8080:80  
Network=app-network.network  
```
##### Database
Volume definition found at: ~/.config/containers/systemd/db-data.volume
```
[Volume]
User=1000:1000
Options=o=bind
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
Name=db
Network=app-network.network
Port=5432:5432
Pod=app-pod.pod

[Service]
Restart=always
RestartSec=30
```
Note: We have put secrets directly into a quadlet file which is a bad practice. We have this here for illustrative purposes only. Better practices can be found below. 

#### Deploy Quadlet
```
systemctl --user daemon-reload
systemctl --user enable --now db.service
systemctl --user enable --now webapp.service 
```
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

Podman natively supports secrets through Podman secrets. They are encrypted by the host's kernel keyring service and can be rotated with `podman secret rotate`

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
Secret=db_password,type=env,target=POSTGRES_PASSWORD  # Inject as env var
# OR
Secret=db_password,type=mount,target=/run/secrets/db_password  # Mount as file
```

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

More comfortable with docker and docker compose? Podman still offers podman-compose but it is not well supported and often runs into bugs. Instead, you can utilize `podlet` to convert from docker compose or docker run to quadlet files.

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
| podman system prune -a | Remove unused containers, images, and networks |

### Advanced (Rootful Only)
| Command | Description |
| ----------- | ----------- |
| sudo podman container checkpoint <container> | Save the state of a running container (rootful only) |
| sudo podman container restore <container> | Restore a container from a checkpoint (rootful only) |
| sudo podman container checkpoint <container> -a /tmp/checkpoint.tar.zstd | Export a checkpoint for migration (rootful only) |
| sudo podman container restore -i /tmp/checkpoint.tar/zstd | Restore a container from an exported checkpoint (rootful only) |

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
- Ensure podman machine is running
    - `podman machine list`

## Useful Links
- https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes
- https://www.reddit.com/r/podman/comments/1bmkv1q/rootless_containers/
- https://docs.podman.io/en/stable/Commands.html
- https://mpolinowski.github.io/docs/DevOps/Linux/2019-09-25--podman-cheat-sheet/2019-09-25/
- https://www.redhat.com/en/blog/podman-features-2
- https://developers.redhat.com/blog/2020/09/25/rootless-containers-with-podman-the-basics