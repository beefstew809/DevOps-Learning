# Multi-Container Quadlet

Reddit user mjk3syx gave a great example of an Application Foo with a server, database, and reverse proxy

See https://www.reddit.com/r/podman/comments/1jj2iaj/quadlets_more_files_necessary_than_dockercompose/mjk3syx/

## foo.pod
```
[Unit]
Description=foo pod

[Pod]
PodName=foo
PublishPort=8443:443

[Install]
WantedBy=default.target
```

## foo-db.container
```
[Unit]
Description=foo database

[Container]
Image=foo-db:latest
ContainerName=foo-db
Pod=foo.pod
AutoUpdate=registry
HealthCmd=healthcheck.sh
HealthOnFailure=kill
Notify=healthy

[Service]
Restart=always
```

## foo-server.container
```
[Unit]
Description=foo server
After=foo-db.service

[Container]
Image=foo-server:latest
ContainerName=foo-server
Pod=foo.pod
AutoUpdate=registry
HealthCmd=healthcheck.sh
HealthOnFailure=kill
Notify=healthy

[Service]
Restart=always
```

## foo-proxy.container
```
[Unit]
Description=foo reverse proxy
After=foo-server.service

[Container]
Image=foo-proxy:latest
ContainerName=foo-proxy
Pod=foo.pod
AutoUpdate=registry
HealthCmd=healthcheck.sh
HealthOnFailure=kill
Notify=healthy

[Service]
Restart=always
```

## Run the Pod
`systemctl --user start foo-pod.service`

## Notes
Other settings such as a .network or .volume files can be used here as well but were omitted in this example. 