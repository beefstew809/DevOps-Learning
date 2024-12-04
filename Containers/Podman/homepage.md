# Homepage
https://gethomepage.dev/

## Initial Setup
```
mkdir ~/podman
id -u
id -g
# Note those values
chown <number from id -u>:<number from id -g> ~/podman/
chmod -R u+rwX ~/podman/

#Allow port through firewall. Change to different port if needed
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --reload
```

## Test Run Container
```
podman run -p 3000:3000 -d --name testhome -v ~/podman:/app/config:z ghcr.io/gethomepage/homepage:latest

podman logs -f testhome

#Ensure the container is working
```

Keep the container running so that we can create a kube file from it

`podman kube generate testhome`

Copy the contents of that file

See https://docs.podman.io/en/v5.3.1/markdown/podman-kube-generate.1.html for more information. This gives information on replicas and more examples for volumes.

## Quadlet with kube file

`mkdir -p ~/.config/containers/systemd/`

`vim ~/.config/containers/systemd/homepage.yml`

Copy the contents of the kube generate command:
```
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

### Kube Quadlet File
`vim ~/.config/containers/systemd/homepage.kube`
```
[Unit]
Description=Podman-managed Pod for testhome

[Kube]
Yaml=homepage.yml
Network=testhome-network.network
PublishPort=3000:3000
```
### Enable Service
```
systemctl --user daemon-reload
systemctl --user enable homepage.kube
systemctl --user start homepage.kube
```


## Alternative with Quadlet only
If you don't want to use a kube file, you can run with just quadlet files

### Volume
`vim ~/.config/containers/systemd/homepage.volume`
```
[Unit]
Description=Volume for testhome config

[Volume]
HostPath=/home/homepagsrv/podman
Type=Directory
MountOptions=z
```

### Container
`vim ~/.config/containers/systemd/homepage.container`
```
[Unit]
Description=Podman Container for testhome
Wants=homepage.volume
After=homepage.volume

[Container]
Image=ghcr.io/gethomepage/homepage:latest
Name=testhome
Port=3000:3000
Environment=PUID=1000
Environment=PGID=1000

[Service]
Restart=always
```

### Enable Service
```
systemctl --user daemon-reload
systemctl --user enable homepage.container
systemctl --user start homepage.container
```
