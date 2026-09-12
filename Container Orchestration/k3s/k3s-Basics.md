# K3s

https://docs.k3s.io/

Lightweight Kubernetes in a single binary. Packaged as one process with containerd,
flannel, CoreDNS, Traefik and a local-path storage provisioner already included, so
a usable cluster comes up without installing anything else. Good fit for a homelab
where a full kubeadm control plane is more machine than the workload needs.

## Quick install (server node)

```bash
curl -sfL https://get.k3s.io | sh -
```

That installs the binary, writes a systemd unit called `k3s`, and starts it. Check it:

```bash
sudo systemctl status k3s
sudo k3s kubectl get nodes
```

## Add an agent node

Get the token from the server:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Then on the node to join:

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://myserver:6443 K3S_TOKEN=mynodetoken sh -
```

`K3S_URL` is what makes the installer set up an agent instead of another server.

## Using kubectl from your workstation

The kubeconfig k3s writes is root-owned at `/etc/rancher/k3s/k3s.yaml`:

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy it to the workstation and replace the `server:` address — it says `127.0.0.1`,
which only works on the node itself:

```bash
mkdir -p ~/.kube
scp user@myserver:/etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s
sed -i 's|127.0.0.1|myserver|' ~/.kube/config-k3s
export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes
```

## Install options worth knowing

Pass flags to the installer through `INSTALL_K3S_EXEC`:

```bash
# Skip the bundled Traefik if you already run your own reverse proxy
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -

# Skip the bundled load balancer too
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb" sh -

# Pin a version instead of taking latest
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.31.4+k3s1" sh -
```

Disabling the bundled Traefik is the common one in a homelab that already has a
reverse proxy — see [../../reverse_proxy/traefik.md](../../reverse_proxy/traefik.md).

## Uninstall

The installer leaves a script, which is the only clean way to remove it:

```bash
# server
/usr/local/bin/k3s-uninstall.sh

# agent
/usr/local/bin/k3s-agent-uninstall.sh
```

## Notes

- Manifests dropped in `/var/lib/rancher/k3s/server/manifests/` are applied
  automatically at startup. Handy, and surprising the first time something you
  deleted comes back.
- `k3s kubectl` is the bundled kubectl. A standalone `kubectl` works fine against
  the same kubeconfig.
- Single-server installs keep state in SQLite, not etcd. For HA you need either an
  external datastore or `--cluster-init` with embedded etcd and an odd number of
  servers.
