Windows Collection Links:
- https://galaxy.ansible.com/ui/repo/published/ansible/windows/docs/
- https://galaxy.ansible.com/ui/repo/published/community/windows/docs/
- https://galaxy.ansible.com/ui/repo/published/microsoft/iis/docs/
- https://galaxy.ansible.com/ui/repo/published/microsoft/sql/docs/
- https://galaxy.ansible.com/ui/repo/published/community/general/docs/
- https://galaxy.ansible.com/ui/repo/published/ansible/posix/docs/
- https://galaxy.ansible.com/ui/repo/published/ansible/utils/docs/
- https://galaxy.ansible.com/ui/repo/published/ansible/scm/docs/
- https://galaxy.ansible.com/ui/repo/published/ansible/netcommon/docs/

## Before build

Before building, run the following:

Note that you may need to change the tag

```
podman login registry.redhat.io
Username: {REGISTRY-SERVICE-ACCOUNT-USERNAME}
Password: {REGISTRY-SERVICE-ACCOUNT-PASSWORD}
Login Succeeded!

podman pull registry.redhat.io/ansible-automation-platform-25/ee-supported-rhel8:1.0.0-1032
```

## To Build
`ansible-builder build --tag windows-ee:1.0.0`