# Podman

## Install Container-Tools
https://access.redhat.com/solutions/3650231 

Container-tools includes podman, buildah, skopeo, CRIU, udica, and required libraries

### RHEL 8
`sudo yum module install container-tools`

### RHEL 9
`sudo dnf install container-tools`

## Install Networking
https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md#networking-configuration

### RHEL 8
slirp4netns is the default for RHEL 8

`sudo dnf install slirp4netns`

### RHEL 9
pasta using the package name passt is the default since Podman 5.0

`sudo dnf install passt`

If you need to change the default, change the [network] section of /usr/share/containers/containers.conf, /etc/containers/containers.conf, and /etc/containers/containers.conf.d/*.conf

## Configure subuid and subgid
https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md#etcsubuid-and-etcsubgid-configuration

Configure /etc/subuid and /etc/subgid with the following format:

`<username>:<initial UID or GID>:<size of the range of UIDs or GIDs>`

Example /etc/subuid
```
johndoe:100000:65536
janetest:165536:65536
```

This can also be done via the CLI with:

`sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 johndoe`

If your user is already running containers when you edit subuid and subgid ranges, you need to run the following:

`podman system migrate`

Note the lack of sudo; run this as the user so that you do not interrupt other users containers as this will restart the running containers. See https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-migrate.1.md

## Useful Commands

Show images available to be used:

`podman image ls` or `buildah images`

Show all containers that the user has access to:

`podman ps -a` or `buildah containers`

Inspect a container for metadata and details:

`podman inspect <container name>`

View the containers logs:

`podman logs <container_id>`

View container's pids:

`podman top <container_id>`

Checkpoint your container (not available in rootless mode):

```
sudo podman container checkpoint <container_id>
sudo podman container restore <container_id>
```

Migrate the container from one host to another (stops the container during migration):

```
sudo podman container checkpoint <container_id> -e /tmp/checkpoint.tar.gz
# Copy to destination system
sudo podman container restore -i /tmp/checkpoint.tar.gz
```

## Useful Links
https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes
https://www.reddit.com/r/podman/comments/1bmkv1q/rootless_containers/