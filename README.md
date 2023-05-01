# buildenv

Common build and run containers for Luther applications.

## Local Testing

Build locally and test with:
```
cd images && make PLATFORMS=$(../scripts/local_platform.sh) DOCKER_BUILDX_OPTS=--load
```
For the above command to work the `jq` tool has to be installed. Otherwise
replace the PLATFORMS variable with your local docker server/engine details
(e.g. "linux/arm64" -- see `docker version`).

and set your `BUILDENV_TAG` in `common.mk` to the below version:
```
make echo:VERSION
```

## Releases

Github actions is configured to push releaes on version tag pushes. Create a
release for the new version via the github UI and it will automatically kick
off the release pipeline.
