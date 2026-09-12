# Buildah

https://buildah.io/

The Buildah package provides a command line tool that can be used to:

- create a working container, either from scratch or using an image as a starting point
- create an image, either from a working container or via the instructions in a Dockerfile
- images can be built in either the OCI image format or the traditional upstream docker image format
- mount a working container's root filesystem for manipulation
- unmount a working container's root filesystem
- use the updated contents of a container's root filesystem as a filesystem layer to create a new image
- delete a working container or an image
- rename a local container

Source: https://github.com/containers/buildah?tab=readme-ov-file#buildah---a-tool-that-facilitates-building-open-container-initiative-oci-container-images

## Build from a Containerfile

The common path. `buildah build` reads a Containerfile/Dockerfile exactly as
`podman build` does, and is the same code underneath:

```bash
buildah build -t myimage:latest .
buildah build -f Containerfile.dev -t myimage:dev .
```

(`buildah bud` is the old name for this and still works as an alias.)

## Install Packages using the host machine

This is the scratch-build approach: mount a container's filesystem and install into
it with the host's package manager, without a Containerfile.

Note: `--releasever` takes the number or name that corresponds with the host OS
```
buildah unshare
container=$(buildah from <ImageID>)
mnt=$(buildah mount $container)
dnf install --releasever=9.5 --installroot=$mnt cmake  -y
dnf clean --installroot $mnt all
buildah unmount $container
buildah commit $container demo-container

buildah images

# Test the committed image by the name given to commit:
podman run --rm demo-container cmake --version
```

`buildah unshare` spawns a subshell inside your user namespace — the commands after
it run in that shell, which is what makes `buildah mount` work rootless. Run them
interactively rather than expecting the block to work as a single script.

Use `localhost/demo-container` if the bare name is ambiguous.

Resource: https://gcore.com/learning/everything-you-need-to-know-about-buildah/