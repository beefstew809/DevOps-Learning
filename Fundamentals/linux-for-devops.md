# Linux for DevOps

The layer underneath containers, Kubernetes and cloud instances. Container isolation, systemd
units, cgroup limits and file permissions are all Linux primitives, so debugging them means
dropping to this level.

## systemd

The init system and service manager on every mainstream distribution. Units are the objects it
manages.

| Suffix | What it is |
| --- | --- |
| `.service` | A process |
| `.timer` | A scheduled trigger for a service |
| `.socket` | Socket activation |
| `.mount` / `.automount` | A filesystem |
| `.target` | A grouping, roughly a runlevel |
| `.path` | Filesystem watch trigger |

```bash
systemctl status nginx
systemctl start|stop|restart|reload nginx
systemctl enable --now nginx          # enable at boot AND start now
systemctl disable --now nginx
systemctl cat nginx                   # the effective unit, including drop-ins
systemctl show nginx                  # every property, resolved
systemctl list-units --failed
systemctl daemon-reload               # after ANY unit file change
```

`reload` re-reads config without dropping connections where the service supports it; `restart`
stops and starts. Reaching for `restart` when `reload` exists is a self-inflicted outage.

`systemctl cat` is the command to use rather than reading `/etc/systemd/system/foo.service` —
it shows the base unit plus every drop-in override in the order they apply.

### Drop-ins beat editing

Never edit a packaged unit in `/usr/lib/systemd/system/` — the next update overwrites it. Override
with a drop-in:

```bash
systemctl edit nginx          # creates /etc/systemd/system/nginx.service.d/override.conf
```

```ini
[Service]
Restart=always
RestartSec=5
LimitNOFILE=65535
```

One gotcha: for list-valued directives like `ExecStart=` and `Environment=`, a drop-in **appends**
unless you clear it first:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/myapp --new-flag
```

Forgetting the empty assignment gives a unit with two `ExecStart` lines, which fails to start for
`Type=simple`.

### User units

```bash
systemctl --user status myapp
loginctl enable-linger "$USER"        # keep user units running after logout
```

Rootless containers run as user units. Without `enable-linger` they stop when the session ends —
see [../Containers/Podman/quadlets.md](../Containers/Podman/quadlets.md).

### Dependencies, correctly

```ini
[Unit]
Wants=network-online.target        # weak: start it, proceed regardless
After=network-online.target        # ordering only, no requirement
Requires=postgresql.service        # strong: if it fails, we fail
BindsTo=postgresql.service         # strongest: if it stops, we stop
```

**`After=` is ordering, not requirement.** `After=db.service` alone starts your service after the
database *attempts* to start, whether it succeeded or not. Requirement needs `Requires=`.

`RequiresMountsFor=` is worth a specific warning: on an idle automount it can trigger the mount at
boot and, if the mount fails, take the dependent service down. Prefer `Wants=`/`After=` on the
`.automount` unit.

### Timers over cron

```ini
# /etc/systemd/system/backup.timer
[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl list-timers --all
systemd-analyze calendar "Mon *-*-* 03:00:00"    # verify an OnCalendar expression
```

Advantages over cron that matter operationally: output goes to the journal rather than mail,
`Persistent=true` runs a job missed while the host was off, `OnFailure=` can trigger an alert unit,
and resource limits apply.

### Hardening a unit

```ini
[Service]
User=myapp
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/myapp
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

```bash
systemd-analyze security myapp.service
```

That last command scores a unit and lists what is unprotected. It is the fastest way to harden
something you did not write.

## journald

```bash
journalctl -u nginx -n 100 --no-pager
journalctl -u nginx -f
journalctl -u nginx --since "1 hour ago" --until "10 min ago"
journalctl -p err -b                 # errors, this boot
journalctl -b -1                     # previous boot — what happened before the reboot
journalctl --disk-usage
journalctl --vacuum-time=7d
journalctl -k                        # kernel ring buffer
journalctl _PID=1234
journalctl -u myapp -o json-pretty   # structured fields
```

`journalctl -b -1 -p err` is the first command after an unexplained reboot.

Note the journal is **not persistent by default** on some distributions — logs vanish on reboot
unless `/var/log/journal` exists:

```bash
mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal
```

Cap it in `/etc/systemd/journald.conf` (`SystemMaxUse=1G`) or it grows to 10% of the filesystem.

## Processes and resources

```bash
ps aux --sort=-%mem | head
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu | head
pstree -p
top        # or htop / btop
```

### Load average is not CPU usage

`1.50 0.80 0.45` is the number of processes runnable **or in uninterruptible sleep**, averaged over
1, 5 and 15 minutes. So load includes processes blocked on disk or NFS — a load of 20 with idle
CPUs means IO wait, not CPU saturation.

Compare against core count: load 4 on 4 cores is saturated; on 32 cores it is idle.

```bash
nproc
vmstat 1 5        # r = runnable, b = blocked, wa = IO wait
iostat -xz 1      # per-device, %util and await
```

High `wa` in `vmstat` with low `us`/`sy` is an IO problem. That distinction redirects the whole
investigation.

### Memory is not what `free` first suggests

```bash
free -h
```

**Look at `available`, not `free`.** Linux uses spare memory for page cache by design, so low
`free` is normal and healthy. `available` estimates what a new process could get.

```bash
# who died to the OOM killer
journalctl -k | grep -i -E 'killed process|out of memory'
dmesg -T | grep -i oom
cat /proc/meminfo
```

The OOM killer picks by score, not by who allocated last, so the killed process is frequently not
the cause. Check what else grew.

### Signals and shutdown

| Signal | Effect |
| --- | --- |
| `SIGTERM` (15) | Polite shutdown — the default for `kill` and for containers |
| `SIGKILL` (9) | Immediate, cannot be caught, no cleanup |
| `SIGHUP` (1) | Conventionally "reload config" |
| `SIGUSR1/2` | Application-defined |

```bash
kill <pid>            # TERM
kill -HUP <pid>
kill -9 <pid>         # last resort
pkill -f 'pattern'
```

A process that ignores `SIGTERM` takes the full stop timeout before being killed. In containers
this is the 30-second delay on `docker stop` — usually caused by shell-form `CMD` leaving the app
as a child of `sh`. See
[../Containers/docker/dockerfile-best-practices.md](../Containers/docker/dockerfile-best-practices.md).

## cgroups and limits

What container resource limits actually are.

```bash
systemd-cgtop
systemd-cgls
cat /sys/fs/cgroup/memory.max
cat /sys/fs/cgroup/cpu.stat | grep throttled
```

```ini
[Service]
MemoryMax=512M
MemoryHigh=400M      # throttle and reclaim before the hard limit
CPUQuota=50%
TasksMax=100
IOWeight=50
```

The asymmetry from
[../Container Orchestration/kubernetes/kubernetes-core-objects.md](../Container%20Orchestration/kubernetes/kubernetes-core-objects.md)
applies here too: exceeding a memory limit **kills**; exceeding a CPU quota **throttles**. A
CPU-throttled service is slow with no error in any log, and `cpu.stat`'s `throttled_usec` is the
only direct evidence.

### ulimits

```bash
ulimit -a
ulimit -n              # open file descriptors — the one that bites
cat /proc/<pid>/limits
```

`LimitNOFILE=65535` in the unit is the systemd equivalent. A server hitting the default 1024 FDs
fails with "too many open files" under load, which reads like an application bug.

## Filesystems and disk

```bash
df -h
df -i                  # INODES — a disk can be full of tiny files with space left
du -sh /var/* | sort -h
lsblk -f
findmnt
```

`df -i` is the one people forget. "No space left on device" with `df -h` showing free space is
inode exhaustion, typically from millions of small files.

```bash
# what is actually consuming space
ncdu /var
du -xhd1 /var | sort -h

# deleted-but-held-open files: space not freed until the process closes them
lsof +L1
```

That last case is a genuine puzzle the first time: a log was deleted but the writer still holds
the descriptor, so space does not return until the process is restarted. `df` and `du` disagree,
which is the tell.

```bash
# fstab with a safe automount
# server:/export /mnt/data nfs4 noauto,x-systemd.automount,x-systemd.idle-timeout=600 0 0
```

`x-systemd.automount` in `/etc/fstab` generates the `.automount` unit — that *is* the systemd
method, and `findmnt` reporting `autofs` for it is expected, not a sign of the old autofs daemon.
Never set `mode=` on an automount point; it chmods the export itself when triggered.

## Permissions

```bash
ls -l
# -rw-r--r--  owner / group / other
chmod 640 file
chmod u+x,g-w file
chown user:group file
```

Numeric: read 4, write 2, execute 1. On a **directory**, execute means "may traverse" and read
means "may list" — so `chmod 644` on a directory makes it unusable, which catches people.

Special bits:

```bash
chmod 4755 binary      # setuid  — runs as owner
chmod 2775 dir         # setgid  — new files inherit the group
chmod 1777 /tmp        # sticky  — only the owner may delete their files
```

`setgid` on a shared directory is the clean fix for "files created by one user are unreadable by
the group".

ACLs, when POSIX bits are not enough:

```bash
getfacl /srv/shared
setfacl -m u:deploy:rwx /srv/shared
setfacl -d -m g:devs:rx /srv/shared     # default for new files
```

SELinux, on RHEL/Fedora — the cause of many "permission denied with correct permissions":

```bash
getenforce
ls -lZ /srv/web
restorecon -Rv /srv/web
ausearch -m AVC -ts recent              # what was denied and why
setsebool -P httpd_can_network_connect 1
```

`ausearch -m AVC` is the answer when permissions look right and access still fails. Disabling
SELinux is not a fix. For container volumes, `:z`/`:Z` relabel the mount — see
[../Containers/Podman/Use-Podman.md](../Containers/Podman/Use-Podman.md).

## Shell practices for scripts

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```

- `-e` exit on error, `-u` error on unset variable, `-o pipefail` fail if any pipe stage fails.
  Without `pipefail`, `false | true` succeeds — which silently breaks a lot of scripts.
- Quote every expansion: `"$var"`, `"$@"`.
- `trap 'rm -rf "$tmp"' EXIT` for cleanup.
- `mktemp -d` rather than a fixed `/tmp` path.
- `shellcheck` in CI. It catches real bugs, not style.

```bash
# a template that behaves
set -euo pipefail
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
```

Note `set -e` does not fire inside `if`, `&&`, or a function whose result is tested — so check
exit codes explicitly where it matters.

## Quick triage on a sick host

```bash
uptime                         # load vs nproc
free -h                        # available, not free
df -h; df -i                   # space AND inodes
systemctl list-units --failed
journalctl -p err -b --no-pager | tail -50
ss -tlnp                       # what is listening
vmstat 1 5                     # r/b/wa — CPU vs IO
ps aux --sort=-%mem | head -5
journalctl -k | grep -i oom
```

That sequence answers "what is wrong with this box" in under a minute most of the time.

## Related

- [../Containers/Podman/Configure-Rootless-Podman.md](../Containers/Podman/Configure-Rootless-Podman.md) — subuid/subgid, user namespaces
- [../Containers/Podman/quadlets.md](../Containers/Podman/quadlets.md) — systemd units for containers
- [../Networking/networking-fundamentals.md](../Networking/networking-fundamentals.md)
- [../Observability/observability-fundamentals.md](../Observability/observability-fundamentals.md) — USE and saturation
