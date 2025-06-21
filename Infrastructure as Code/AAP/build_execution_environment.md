# Build Execution Environment

## Prerequisites
- podman/docker
- python3
- python3-pip
- ansible-navigator/ansible-builder (install with ansible-dev-tools)

```
sudo dnf install podman python3 python3-pip
pip install ansible-dev-tools
```
## Example
### Create the execution-environment.yml file
Create a project folder

`mkdir my_ee && my_ee`

Create execution-environment.yml and add:
```
---
version: 3

images:
  base_image:
    name: registry.fedoraproject.org/fedora:42

dependencies:
  python_interpreter:
    package_system: python3==3.12
  ansible_core:
    package_pip: ansible-core==2.14.3
  ansible_runner:
    package_pip: ansible-runner
  system:
  - openssh-clients
  - sshpass
  galaxy:
    collections:
    - name: community.postgresql
```

### Build the image
```
ansible-builder build --tag postgres_ee

podman image list
> localhost/postgresql_ee          latest      2e866777269b  6 minutes ago  1.11 GB
```

### Build the image in CI/CD
Example snippet:
```
build-windows:
  stage: build
  image: ghcr.io/ansible/community-ansible-dev-tools:25.5.2
  rules:
    - changes:
        - ee-windows/**/*
  script:
    - cd $EE_DIR
    - echo $REDHAT_PASS | podman login registry.redhat.io -username $REDHAT_USER --password-stdin
    - echo $REGISTRY_PASSWORD | podman login $REGISTRY --username $REGISTRY_USERNAME --password-stdin
    - ansible-builder build --tag $REGISTRY/{$EE_NAME}:${CI_COMMIT_SHORT_SHA}
    - podman logout registry.redhat.io
    - podman logout $REGISTRY
  artifacts:
    paths:
      - ee-windows/context
      - ee-windows/ansible-builder.log
  tags:
    - podman-vm
```

## Best Practices
- For each dependency or collection, append the version:
```
dependencies:
    python:
      - pywinrm==3.14
    system:
      - iputils [platform:rpm]
    galaxy:
      collections:
        - name: community.windows
        - name: ansible.utils
          version: 2.10.1
    ansible_core:
        package_pip: ansible-core==2.14.2
    ansible_runner:
        package_pip: ansible-runner==2.3.1
    python_interpreter:
        package_system: "python310"
        python_path: "/usr/bin/python3.10"
```

You can use files to host requirements and dependencies:
```
dependencies:
    python: requirements.txt
    system: bindep.txt
    galaxy: requirements.yml
    ansible_core:
        package_pip: ansible-core==2.14.2
    ansible_runner:
        package_pip: ansible-runner==2.3.1
    python_interpreter:
        package_system: "python310"
        python_path: "/usr/bin/python3.10"
```

## Read More
- https://docs.ansible.com/ansible/devel/getting_started_ee/setup_environment.html
- https://docs.ansible.com/ansible/devel/getting_started_ee/build_execution_environment.html
- https://ansible.readthedocs.io/projects/builder/en/stable/definition/