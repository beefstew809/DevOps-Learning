# Kubernetes Storage

https://kubernetes.io/docs/concepts/storage/

A container's filesystem dies with the container. Storage in Kubernetes is the set of
abstractions that let a pod keep data across restarts, rescheduling, and node failure —
while not knowing what the underlying storage actually is.

## The three objects

```
StorageClass      "how to make storage"  — cluster-scoped, set up once
      ↓ provisions
PersistentVolume  "a piece of storage that exists" — cluster-scoped
      ↕ bound 1:1
PersistentVolumeClaim "an app's request for storage" — namespaced
      ↓ mounted by
Pod
```

You write the **PVC**. Everything else is usually automatic.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
```

```yaml
# in the pod spec
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data
containers:
  - name: app
    volumeMounts:
      - name: data
        mountPath: /var/lib/app
```

### Static vs dynamic provisioning

**Dynamic** (normal): the PVC names a StorageClass, a provisioner creates a PV to match,
they bind. **Static**: an admin pre-creates PVs and the PVC binds to whichever fits.

Static binding is loose and surprises people — a PVC asking for 10Gi can bind to a
pre-made 100Gi PV, and you are charged for 100Gi. Dynamic provisioning avoids that.

## Access modes

| Mode | Short | Meaning |
| --- | --- | --- |
| `ReadWriteOnce` | RWO | One **node** may mount it read-write |
| `ReadOnlyMany` | ROX | Many nodes, read-only |
| `ReadWriteMany` | RWX | Many nodes, read-write |
| `ReadWriteOncePod` | RWOP | Exactly one **pod** |

The detail that matters: **RWO is per node, not per pod.** Several pods on the *same*
node can share an RWO volume. Schedule one onto a different node and it will not start.

This is why a `ReadWriteOnce` Deployment scaled to 2 replicas often has one pod stuck
in `ContainerCreating` forever — the second landed on another node and cannot attach a
volume that is already attached elsewhere. Most block storage (EBS, most CSI drivers,
k3s local-path) is RWO only. RWX needs a file protocol — NFS, CephFS, EFS, Azure Files.

So: **block storage does not scale horizontally.** If several pods must write the same
data, you need RWX or a different design (object storage, or a database).

## StorageClass

```bash
kubectl get storageclass
```

The one marked `(default)` is used by PVCs that name none. A cluster with no default and
a PVC with no `storageClassName` leaves the PVC `Pending` forever with no obvious error
— check for the default first.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

Three fields worth understanding:

**`reclaimPolicy`** — what happens to the PV when the PVC is deleted.

- `Delete` — the underlying volume is destroyed. Data gone.
- `Retain` — the PV stays, holding the data, in `Released` state. It will **not** rebind
  to a new PVC automatically; an admin must clear `spec.claimRef`.

Dynamic provisioning defaults to `Delete`. For anything whose loss would hurt, set
`Retain` and accept the manual step. A `helm uninstall` that takes the database volume
with it is a one-line consequence of this default.

**`volumeBindingMode`** — `Immediate` binds as soon as the PVC is created;
`WaitForFirstConsumer` waits until a pod is scheduled. Use the latter on anything
topology-constrained (zonal disks, local disks), or you get a volume in zone A and a pod
that can only be scheduled in zone B.

**`allowVolumeExpansion`** — whether PVCs can grow later. You cannot retrofit this onto
existing volumes easily, so enable it from the start.

## Growing a volume

```bash
kubectl patch pvc data -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
kubectl get pvc data -w
```

Shrinking is not supported, by any driver. Some drivers need the pod restarted for the
filesystem resize to complete — `describe pvc` shows a
`FileSystemResizePending` condition when that is the case.

## Ephemeral volumes

Not everything needs persistence:

```yaml
volumes:
  - name: cache
    emptyDir: {}                    # lives and dies with the POD, survives container restarts
  - name: scratch
    emptyDir:
      medium: Memory                # tmpfs — counts against the pod's memory limit
      sizeLimit: 256Mi
  - name: config
    configMap: { name: app-config }
  - name: creds
    secret: { secretName: db-creds }
```

`emptyDir` survives a container crash but not rescheduling. `medium: Memory` is the
right choice for a read-only root filesystem needing a writable `/tmp` — but remember it
consumes the pod's memory allowance, so an unbounded tmpfs can get the pod OOMKilled.

The `projected` volume type combines several sources into one directory, which is how
service account tokens are mounted.

## StatefulSets and volumeClaimTemplates

A Deployment cannot give each replica its own volume — every pod references the same
PVC. StatefulSets solve this with `volumeClaimTemplates`, which creates a PVC **per
pod**:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db            # must be a headless Service
  replicas: 3
  selector:
    matchLabels: { app: db }
  template:
    metadata:
      labels: { app: db }
    spec:
      containers:
        - name: postgres
          image: docker.io/library/postgres:17
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: fast
        resources:
          requests:
            storage: 20Gi
```

Produces `data-db-0`, `data-db-1`, `data-db-2`. Each pod keeps its own volume across
restarts and rescheduling, which is exactly what a database replica needs.

**Deleting the StatefulSet does not delete these PVCs.** That is deliberate — it means
you can delete and recreate the StatefulSet without losing data, and it means scaling
down then up reattaches the original volume. It also means storage accumulates
invisibly:

```bash
kubectl get pvc -l app=db        # clean up by hand when you really mean it
```

## Why a PVC is Pending

The most common storage problem. In order of likelihood:

```bash
kubectl describe pvc data        # events at the bottom say which of these it is
```

| Cause | Signal |
| --- | --- |
| No default StorageClass and none named | No provisioner event at all |
| StorageClass name typo | `storageclass.storage.k8s.io "fastt" not found` |
| `WaitForFirstConsumer` and no pod yet | `waiting for first consumer` — **normal**, not an error |
| Provisioner not running | No events; check the CSI controller pods |
| Quota or capacity exhausted | Provisioner error in events |
| Access mode unsupported | Requested RWX from a block-only driver |

That third row matters: a PVC stuck at `Pending` with `waiting for first consumer to be
created before binding` is working correctly. It binds when a pod mounts it.

## Pod stuck because of a volume

| Symptom | Cause |
| --- | --- |
| `ContainerCreating` forever, `FailedAttachVolume` | Volume attached to another node — RWO with >1 replica, or a failed node still holding it |
| `FailedMount`, timeout | Network storage unreachable (NFS server down, wrong path) |
| Permission denied inside container | UID mismatch; see `fsGroup` below |
| Pod `Terminating` forever | Volume will not detach; the old node is gone or unresponsive |

```bash
kubectl describe pod <pod>
kubectl get volumeattachment          # cluster view of what is attached where
```

### Permission denied on a mounted volume

Fresh volumes are owned by root. A container running as non-root cannot write to one.
`fsGroup` makes the kubelet chown the volume's contents to that group at mount:

```yaml
spec:
  securityContext:
    fsGroup: 1000
    fsGroupChangePolicy: OnRootMismatch    # skip the recursive chown if already right
```

`OnRootMismatch` matters at scale — without it, the kubelet recursively chowns every
file on every mount, which on a large volume delays pod start by minutes.

## Snapshots

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: db-before-upgrade
spec:
  volumeSnapshotClassName: csi-snapshot
  source:
    persistentVolumeClaimName: data-db-0
```

Restore by using the snapshot as a PVC's `dataSource`. Requires a CSI driver that
supports snapshots plus the snapshot controller installed — it is not built in.

**A snapshot is not a backup.** It usually lives in the same storage system as the
volume, so it does not survive that system failing, and for a database it is only
consistent if the database was quiesced or its engine handles crash-consistent restore.
Treat snapshots as fast rollback, and keep real backups elsewhere — see
[../../Backups/backup-strategy.md](../../Backups/backup-strategy.md).

## Related

- [kubernetes-core-objects.md](kubernetes-core-objects.md) — StatefulSet vs Deployment
- [../../Backups/backup-strategy.md](../../Backups/backup-strategy.md)
- [../../Cloud/AWS/storage-and-databases.md](../../Cloud/AWS/storage-and-databases.md) — EBS/EFS/S3 behind the CSI drivers
