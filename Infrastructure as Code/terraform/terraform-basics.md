# Terraform

https://developer.hashicorp.com/terraform/docs

Declarative infrastructure. You describe the resources you want, Terraform diffs
that against recorded state and makes the minimum set of API calls to converge.

Where this differs from Ansible: Ansible converges the *inside* of a machine that
already exists, running tasks in order. Terraform creates and destroys the
resources themselves — DNS records, VMs, cloud objects — and works out the order
from the dependency graph. They compose: Terraform makes the host, Ansible
configures it.

## Install

Via the Ansible role already declared in
[../ansible/requirements.yml](../ansible/requirements.yml):

```yaml
- hosts: all
  roles:
    - diodonfrost.terraform
```

Or directly from the HashiCorp repo — see
https://developer.hashicorp.com/terraform/install

```bash
# Fedora / RHEL
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install terraform

terraform version
```

## The loop

```bash
terraform init      # download providers, set up the backend. Re-run when either changes.
terraform fmt       # canonical formatting
terraform validate  # syntax and type checking, no API calls
terraform plan      # what would change. Read this every time.
terraform apply     # make it so
terraform destroy   # tear it down
```

`plan` is the whole point. It is the dry run that tells you whether a change is
additive or whether Terraform intends to delete and recreate something.

## Anatomy of a config

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true          # keeps it out of CLI output
}

variable "zone_id" {
  type = string
}

resource "cloudflare_record" "docker1" {
  zone_id = var.zone_id
  name    = "docker1"
  content = "10.0.0.11"
  type    = "A"
  proxied = false
}

output "docker1_fqdn" {
  value = cloudflare_record.docker1.hostname
}
```

Files ending `.tf` in a directory are one configuration — the split across files is
for your benefit, not Terraform's. The conventional layout is `main.tf`,
`variables.tf`, `outputs.tf`, `versions.tf`.

## Variables

Never put secrets in a `.tf` file. Options, roughly in order of preference:

```bash
export TF_VAR_cloudflare_api_token='...'     # environment
terraform apply -var-file=secret.tfvars      # file, gitignored
terraform apply -var='zone_id=abc123'        # inline, ends up in shell history
```

A `terraform.tfvars` in the working directory is loaded automatically, which is
convenient and exactly why it needs to be gitignored.

## State

Terraform records what it created in `terraform.tfstate`.

- **It contains secrets.** Resource attributes are stored in the clear, including
  generated passwords and keys. Treat the state file as sensitive.
- **Never hand-edit it.** Use `terraform state` subcommands.
- **Never commit it** when more than one machine or person will run Terraform —
  two local states diverge silently and then fight.

```bash
terraform state list                    # every resource Terraform knows about
terraform state show <addr>             # one resource in full
terraform import <addr> <id>            # adopt something created by hand
terraform state rm <addr>               # forget it without destroying it
```

`import` is the one to reach for when something already exists — it brings a
hand-made resource under management instead of having Terraform try to create a
duplicate and fail.

## Remote state

For anything beyond a single workstation, move state off local disk. Terraform
supports an HTTP backend, which Forgejo and GitLab both implement:

```hcl
terraform {
  backend "http" {
    address        = "https://git.example.com/api/packages/OWNER/terraform/state/NAME"
    lock_address   = "https://git.example.com/api/packages/OWNER/terraform/state/NAME/lock"
    unlock_address = "https://git.example.com/api/packages/OWNER/terraform/state/NAME/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
  }
}
```

Credentials go in `terraform init -backend-config=...` or the environment, not in
the block.

## Gotchas

- `plan` showing a resource being **destroyed and recreated** usually means you
  changed an attribute that the provider cannot update in place. Check whether the
  provider documents that field as forcing replacement before you apply.
- A provider version with `~>` pins the minor, not the patch. `init` records exact
  versions in `.terraform.lock.hcl` — commit that file.
- `terraform destroy` respects no confirmation beyond one prompt. There is no undo.
