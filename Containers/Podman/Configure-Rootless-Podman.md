# Configure Podman

Podman is a container management tool similar to Docker, but it doesn't require a daemon process and runs containers rootless by default, making it more secure. RHEL has adopted Podman as its native container engine and no longer ships Docker.

Docker commands carry over, but the `docker` name does not appear by itself. It comes from the optional **`podman-docker`** package, which installs a `/usr/bin/docker` shim. On a stock host `docker` does not exist at all:

```bash
sudo dnf install podman-docker   # only if you want the alias
```

This guide will show how to setup rootless Podman

# Install podman on linux host

## Install Container-Tools
https://access.redhat.com/solutions/3650231 

Container-tools includes `podman`, `buildah`, `skopeo`, `CRIU`, `udica`, and required libraries

### RHEL 8
`sudo yum module install container-tools`

### RHEL 9
`sudo dnf install container-tools`

### What tools are installed
**podman** : A daemonless container engine for developing, managing, and running OCI containers that can run as root or in rootless mode.

**buildah** : A tool for building OCI-compliant container images without requiring a full container runtime or daemon.

**skopeo** : A command-line utility that performs various operations on container images and image repositories without requiring the image to be pulled locally.

**CRIU** : Checkpoint/Restore In Userspace is a software tool that enables freezing a running container and saving its state for later restoration.

**udica** : A tool that generates customized SELinux security policies for containers based on container specifications.

## Install Networking
https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md#networking-configuration

### RHEL 8
slirp4netns is the default for RHEL 8

`sudo dnf install slirp4netns`

### RHEL 9
pasta, using the package name passt, is the default since Podman 5.0

`sudo dnf install passt`

If you need to change the default, set `default_rootless_network_cmd` in the
`[network]` section. **Do not edit `/usr/share/containers/containers.conf`** — that
file is owned by the package and your changes are lost on the next update. It is the
documented reference for available settings, nothing more.

Write to one of these instead, in increasing precedence:

| File | Scope |
| --- | --- |
| `/etc/containers/containers.conf` | system-wide override |
| `/etc/containers/containers.conf.d/*.conf` | system-wide drop-in, preferred |
| `~/.config/containers/containers.conf` | this user only — the right place for rootless |

A drop-in only needs the keys you are changing:

```ini
# ~/.config/containers/containers.conf
[network]
default_rootless_network_cmd = "slirp4netns"
```

Confirm what is actually in effect rather than assuming:

```bash
podman info --format '{{.Host.NetworkBackend}}'
podman info --format '{{.Host.RootlessNetworkCmd}}'
```

## Configure subuid and subgid
https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md#etcsubuid-and-etcsubgid-configuration

Podman rootless containers rely on user namespaces, which require each user to have a dedicated range of subordinate UIDs and GIDs. Proper configuration of /etc/subuid and /etc/subgid is essential for security and functionality.

### Understanding the Format

Configure /etc/subuid and /etc/subgid with the following format:

`<username>:<initial UID or GID>:<size of the range of UIDs or GIDs>`

Example /etc/subuid
```
johndoe:100000:65536
janetest:165536:65536
```

### Choosing Ranges: Reccomendations

**Range Size**: The default and recommended range size is `65536` (2^16). This is generally sufficient for most container workloads and matches defaults used by tools like useradd.

**Non-overlapping Ranges**: Each user must have a unique, non-overlapping range. Overlapping ranges can cause security issues and unpredictable behavior.

**Starting Value**: Common practice is to start at `100000` for the first user, then increment by the range size for each subsequent user.

### Checking Existing subuid,subgid Entries

Check what ranges currently exist:

`grep -E '^[^:]+:[0-9]+:[0-9]+' /etc/subuid /etc/subgid`

Example output:
```
/etc/subuid:johndoe:100000:65536
/etc/subgid:janetest:165536:65536
```

List each user's full UID/GID Range:

```
awk -F: '{print $2 " " $3 " " $1}' /etc/subuid | while read start size user; do
  end=$((start+size-1))
  echo "$user: $start-$end"
done

```

Example output:
```
johndoe: 100000-165535
janetest: 165536-231071
```

### Assigning Ranges

You can manually edit /etc/subuid and /etc/subgid, or use the usermod command:

`sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 johndoe`

This command assigns the range 100000-165535 to johndoe for both UIDs and GIDs.

Confirm the ranges have been set with:

```
grep <username> /etc/subuid
grep <username> /etc/subgid
```

### Migrating Running Containers

If your user is already running containers when you edit subuid and subgid ranges, you need to run the following:

`podman system migrate`

Note that we don't use sudo; run this as the user so that you do not interrupt other users containers as this will restart the running containers. See https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-migrate.1.md

## Enable podman.socket for Rootless Podman

To allow Podman to run as a service for your user (enabling features like the REST API and better integration with tools), you need to enable and start the podman.socket user unit.

```bash
systemctl --user enable --now podman.socket
```

`--now` already starts the unit, so a separate `start` is redundant (and `--now` does
nothing on `start`).

Verify it:

```bash
systemctl --user status podman.socket
podman info --format '{{.Host.RemoteSocket.Path}}'
```

**Note**: Run this as the user who will be running containers (not as root, and not with sudo). If you want to enable Podman for another user, switch to that user first.

This socket is only needed by things that speak the **Docker API** — Docker Compose,
Testcontainers, a CI runner configured with `DOCKER_HOST`, Dozzle. Plain `podman`
commands do not use it and work without it. Point clients at it with:

```bash
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
```

## Allow Containers to Persist Unattended (Enable Linger)

By default, user services (like rootless Podman containers) stop when you log out. To allow containers to keep running even after logout, you need to enable "linger" for the user account.

`loginctl enable-linger johndoe`

**Note**: Change johndoe to the user or service account that will be running the service or application container. This is necessary for unattended workloads such as Gitlab runners or web applications

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
- Checkpoint/restore really is root-only. Attempting it rootless fails immediately
  with `Error: checkpointing a container requires root`, because CRIU needs
  capabilities a user namespace does not grant.

## Verifying the setup

```bash
# rootless? Should print "rootless"
podman info --format '{{if .Host.Security.Rootless}}rootless{{else}}ROOTFUL{{end}}'

# the subuid/subgid range podman resolved for this user
podman info --format '{{.Host.IDMappings}}'

# smoke test: the container's root should map to your subordinate range
podman run --rm docker.io/library/alpine:latest id
```

If `podman info` complains about `/etc/subuid`, the range is missing or overlapping —
recheck the section above, then run `podman system migrate`.

**`podman system reset` is the blunt instrument**: it deletes all containers, images,
volumes, networks and configuration for the current user. It is the fix for genuinely
corrupted storage, not a troubleshooting step.

## Useful Links
- https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes
- https://www.reddit.com/r/podman/comments/1bmkv1q/rootless_containers/
- https://docs.podman.io/en/stable/Commands.html
- https://mpolinowski.github.io/docs/DevOps/Linux/2019-09-25--podman-cheat-sheet/2019-09-25/
- https://www.redhat.com/en/blog/podman-features-2
- https://developers.redhat.com/blog/2020/09/25/rootless-containers-with-podman-the-basics