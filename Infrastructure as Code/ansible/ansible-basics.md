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
```
cd AnsibleServer
ansible-galaxy install diodonfrost.terraform -p roles/
ansible-galaxy role install artis3n.tailscale -p roles/
ansible-galaxy role install GROG.package -p roles/
ansible-galaxy role install GROG.fqdn -p roles/
ansible-galaxy role install geerlingguy.docker -p roles/
```

## Ansible Vault
```
ansible-vault create vault.yaml
#Input new vault password
long_key_here
#If you need to edit later
ansible-vault edit vault.yaml
```