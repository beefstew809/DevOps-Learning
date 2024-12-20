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

## Install Packages using the host machine

Note: For the "releaseserver" you need to put the number or name that corresponds with the host OS
```
buildah unshare
container=$(buildah from <ImageID>)
mnt=$(buildah mount $container)
dnf install --releasever=9.5 --installroot=$mnt cmake  -y
dnf clean --installroot $mnt all
buildah unmount $container
buildah commit $container demo-container
 
buildah images

# Test the container:
podman run <ImageID> cmake --version
```

Resource: https://gcore.com/learning/everything-you-need-to-know-about-buildah/