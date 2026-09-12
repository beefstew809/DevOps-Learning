# Homepage
https://gethomepage.dev/

## Initial Setup
```bash
mkdir -p ~/podman/homepage

# Allow port through firewall. Change to a different port if needed.
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --reload
```

The directory is already owned by you, so no `chown` is needed for your own access.
What does matter is that the **container's** user can write to it. A rootless
container runs under your user namespace, so the UID the image uses (say 1000) maps
to some high subordinate UID on the host — not to your 1000. If the container
reports permission denied on `/app/config`, fix it from inside the namespace:

```bash
podman unshare chown -R 1000:1000 ~/podman/homepage
```

`podman unshare` enters your user namespace, so the `1000:1000` there is the
container's 1000, which is what you want. Plain `chown 1000:1000` from the host sets
the wrong owner. The alternative is to skip the mapping entirely with
`UserNS=keep-id`, which makes the container see your own UID.

## Test Run Container
```bash
podman run -p 3000:3000 -d --name testhome \
  -v ~/podman/homepage:/app/config:z \
  ghcr.io/gethomepage/homepage:latest

podman logs -f testhome

# Ensure the container is working
```

Keep the container running so that we can create a kube file from it

`podman kube generate testhome`

Copy the contents of that file

See https://docs.podman.io/en/stable/markdown/podman-kube-generate.1.html for more information. This gives information on replicas and more examples for volumes.

## Quadlet with kube file

`mkdir -p ~/.config/containers/systemd/`

`vim ~/.config/containers/systemd/homepage.yml`

Copy the contents of the kube generate command:
```yaml
---
apiVersion: v1
kind: Pod
metadata:
  annotations:
    bind-mount-options: /home/homepagesrv/podman:z
  creationTimestamp: "2024-12-04T04:10:48Z"
  labels:
    app: testhome-pod
  name: testhome-pod
spec:
  containers:
  - args:
    - node
    - server.js
    image: ghcr.io/gethomepage/homepage:latest
    name: testhome
    ports:
    - containerPort: 3000
      hostPort: 3000
    volumeMounts:
    - mountPath: /app/config
      name: home-homepagesrv-podman-host-0
  volumes:
  - hostPath:
      path: /home/homepagesrv/podman
      type: Directory
    name: home-homepagesrv-podman-host-0
```

Paths in the generated YAML are absolute and reflect whoever ran `kube generate` —
adjust them for the account that will actually run the service.

### Kube Quadlet File
`vim ~/.config/containers/systemd/homepage.kube`
```ini
[Unit]
Description=Podman-managed Pod for testhome

[Kube]
Yaml=homepage.yml

[Install]
WantedBy=default.target
```

The `Network=` and `PublishPort=` lines that were here have been dropped: the ports
are already declared in the YAML (`hostPort: 3000`), and the network referenced a
`testhome-network.network` file that was never defined — a dangling reference that
stops the unit from starting.

### Start the Service
```bash
systemctl --user daemon-reload
systemctl --user start homepage.service
```

Two things to note:

- **The unit is `homepage.service`, not `homepage.kube`.** The Quadlet file name is
  the input; the generator produces a `.service`.
- **There is no `systemctl enable` step.** Generated units cannot be enabled —
  `systemctl --user enable homepage.service` fails with *"is transient or
  generated"*. Starting at boot comes from the `[Install] WantedBy=default.target`
  above, plus `loginctl enable-linger $USER` so your units survive logout.

## Alternative with Quadlet only
If you don't want to use a kube file, you can run with just quadlet files

### Volume
`vim ~/.config/containers/systemd/homepage.volume`
```ini
[Unit]
Description=Volume for testhome config

[Volume]
Driver=local
Device=/home/homepagesrv/podman/homepage
Options=bind
```

`HostPath=` and `MountOptions=` are not Quadlet keys — the generator rejects the
whole file with *"unsupported key 'HostPath' in group 'Volume'"* and no unit appears
at all. A bind-backed named volume needs `Driver=local`, `Device=` for the host path
and `Options=bind`. `Options=` without `Device=` also fails.

Simpler, if you do not need a named volume: skip the `.volume` file and bind-mount
the path directly in the container, as the `Volume=` line below shows.

### Container
`vim ~/.config/containers/systemd/homepage.container`
```ini
[Unit]
Description=Podman Container for testhome

[Container]
Image=ghcr.io/gethomepage/homepage:latest
ContainerName=testhome
PublishPort=3000:3000
Volume=%h/podman/homepage:/app/config:z
Environment=PUID=1000
Environment=PGID=1000
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=default.target
```

Three corrections from the earlier version of this file, each of which stopped the
unit from being generated or from working:

- `Name=` → **`ContainerName=`**. `Name` is not a valid `[Container]` key.
- `Port=` → **`PublishPort=`**. `Port` is not a valid key either.
- A `Volume=` line was missing entirely, so the config directory was never mounted —
  the `.volume` file was declared and then never used. `%h` expands to the user's
  home directory.

The `Wants=`/`After=homepage.volume` lines are also gone. If you do use a `.volume`
file, reference it in `Volume=` and Quadlet adds the dependency for you; the unit to
depend on would be `homepage-volume.service`, not `homepage.volume`.

### Start the Service
```bash
systemctl --user daemon-reload
systemctl --user start homepage.service
```

### Verify
```bash
systemctl --user status homepage.service
podman ps --filter name=testhome
journalctl --user -u homepage.service -n 50 --no-pager
```

If the unit does not exist at all, the generator rejected the file. Ask it why:

```bash
/usr/libexec/podman/quadlet -dryrun -user
```
