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

## .container file

```
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
Network=host
Environment=DATABASE_USER=dbsuer
Timezone=local

Volume=/path/to/storage/containerfolder:/config:rw,Z
PublishPort=8088:8080/tcp

[Service]
Restart=always
TimeoutStartSec=900 # Systemd standard timeout is 90s, which can be too little to pull the image.

```
## Example Application

Source: https://git.mo8it.com/mo8it/main_server/src/commit/14a949bb4f5b08d0666a7161ecfc8942cfa605b9/containers/oxitraffic

### Application
oxitraffic.container
```
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
```
[Container]
Image=docker.io/library/postgres:16
AutoUpdate=registry
Network=oxitraffic.network
Volume=%h/volumes/oxitraffic/db:/var/lib/postgresql/data:Z

EnvironmentFile=%h/volumes/oxitraffic/.postgres.env
Environment=TZ=America/Los Angeles
Environment=PGTZ=America/Los Angeles
Environment=POSTGRES_PASSWORD=CHANGE_ME

[Service]
Restart=always

[Install]
WantedBy=default.target
```

### Network
oxitraffic.network
```
[Network]
```

### Traefik
traefik.container
```
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

traefik.network
```
[Network]
```

## Another Example
Source: https://blog.while-true-do.io/podman-quadlets/

### Network and Volume files
wordpress.network
```
[Unit]
Description=WordPress Container Network

[Network]
Label=app=wordpress
```

wordpress-app.volume
```
[Unit]
Description=WordPress Container Volume

[Volume]
Label=app=wordpress
```

wordpress-db.volume
```
[Unit]
Description=WordPress Database Container Volume

[Volume]
Label=app=wordpress
```

### Application and Database
wordpress-db.container
```
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
# This one should be stored in a secret
Environment=MARIADB_PASSWORD=password

[Install]
WantedBy=multi-user.target default.target
```

wordpress-app.container
```
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
# This one should be stored in a secret
Environment=WORDPRESS_DB_PASSWORD=password
PublishPort=8080:80

[Install]
WantedBy=multi-user.target default.target
```

### Run it
```
systemctl daemon-reload
# See the service
systemctl cat wordpress-app.service

systemctl start wordpress-app.service
```

## Tools

https://github.com/containers/podlet
- Podlet generates Podman Quadlet files from a Podman command, compose file, or existing object

## Secrets

https://www.reddit.com/r/podman/comments/18xlu5g/quadlet_running_podman_containers_under_systemd/lchlbb1/

First, I created a secret file and created the secret with Podman:

`bash echo "secretdata" > secretfile podman secret create secretname secretfile`

Now, I created the following container file ~/.config/containers/systemd/test-secret.container:

```
[Container] Image=docker.io/library/debian:12-slim 
Secret=secretname,type=env,target=SECRET_ENV Exec=bash -c 'echo $SECRET_ENV'
```

Then, I started the container with systemctl --user start test-secret. When running systemctl --user status test-secret, I saw the line containing secretdata which means that the environment 