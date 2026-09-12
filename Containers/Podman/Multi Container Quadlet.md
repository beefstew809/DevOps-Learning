# Multi-Container Quadlet

Reddit user mjk3syx gave a great example of an Application Foo with a server, database, and reverse proxy

See https://www.reddit.com/r/podman/comments/1jj2iaj/quadlets_more_files_necessary_than_dockercompose/mjk3syx/

## foo.pod
```ini
[Unit]
Description=foo pod

[Pod]
PodName=foo
PublishPort=8443:443

[Install]
WantedBy=default.target
```

## foo-db.container
```ini
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
```ini
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
```ini
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

### Why the unit is `foo-pod.service`

The file is `foo.pod` but the generated unit gains a `-pod` suffix. This is the one
Quadlet type where the unit name is not simply the basename plus `.service`:

| File | Unit |
| --- | --- |
| `foo.pod` | `foo-pod.service` |
| `foo-db.container` | `foo-db.service` |
| `app.network` | `app-network.service` |
| `data.volume` | `data-volume.service` |

Starting the pod pulls in the member containers, so you do not start each
`.container` yourself. Only the `.pod` file needs the `[Install]` section.

### Ports belong to the pod, not the containers

Containers joined with `Pod=` share the pod's network namespace, so `PublishPort=`
goes on the `.pod` file only — which is why it appears there and not on the three
containers. Set `Network=` on the pod for the same reason: the members inherit it,
and putting it on an individual container has nothing to act on.

### `Notify=healthy` needs a real health check

`Notify=healthy` holds the unit in *activating* until the container reports healthy,
which is what makes `After=foo-db.service` mean "after the database is actually
ready" rather than merely "after the container started". It only works if
`HealthCmd=` is set and the command genuinely exits non-zero while the service is
unready — `healthcheck.sh` above is a placeholder for whatever the image provides.

Without it, `After=` orders startup but does not wait for readiness, and the server
can race ahead of the database.

`HealthOnFailure=kill` makes systemd's `Restart=always` the recovery path. The
alternatives are `none` (default), `restart`, and `stop`.

### Ordering is still one-directional

`After=` does not imply `Requires=`. As written, the server is ordered after the
database but will still start if the database failed. Add `Requires=foo-db.service`
if the server must not run without it.
