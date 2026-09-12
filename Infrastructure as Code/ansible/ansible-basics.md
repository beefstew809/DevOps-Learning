# Ansible

## Install Ansible Server on Rocky 9

In the terminal of your system, run the following:

```bash
sudo dnf install epel-release
sudo dnf install python3-devel
sudo dnf install python3-pip
pip3 install --upgrade pip
pip3 install ansible
ssh-keygen -t ed25519 -C "Ansible Server" -f .ssh/ansibleserver
ssh-copy-id -i ~/.ssh/ansibleserver.pub user@ip-address
```

## Define Systems
Edit inventory.ini and add systems. Note you can also do this in YAML if preferred.

Edit group_vars and host_vars as needed.

## Install Roles
- https://github.com/diodonfrost/ansible-role-terraform
- https://github.com/artis3n/ansible-role-tailscale
- https://github.com/GROG/ansible-role-package
- https://github.com/GROG/ansible-role-fqdn
- https://github.com/geerlingguy/ansible-role-docker
Declare them in `requirements.yml` with a pinned version rather than installing
them one at a time, so the versions are recorded in git:

```yaml
roles:
  - name: artis3n.tailscale
    version: v4.4.1
  - name: geerlingguy.docker
    version: 7.0.2
```

Then install:

```bash
ansible-galaxy install -r requirements.yml
```

Add `--force` to re-install after bumping a version.

Note: do **not** install with `-p roles/`. That writes the downloaded role into the
repo, which commits someone else's code, records no version, and makes dependency
bots open PRs against upstream internals. Let them install to the default
`roles_path` (`~/.ansible/roles`) and keep only locally written roles in `roles/`.

## Ansible Vault
```
ansible-vault create vault.yaml
#Input new vault password
long_key_here
#If you need to edit later
ansible-vault edit vault.yaml
```