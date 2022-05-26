# buildenv

Common build and run containers for Luther applications.

[![CircleCI](https://circleci.com/gh/luthersystems/buildenv.svg?style=svg)](https://circleci.com/gh/luthersystems/buildenv)

## Local Testing

Build locally and test with (replace architecture):
```
cd images && make PLATFORMS=linux/arm64 DOCKER_BUILDX_OPTS=--load
```

and set your `BUILDENV_TAG` in `common.mk` to the below version:
```
make echo:VERSION
```

## Releases

CircleCI is configured to push releaes on version tag pushes. Create a release
for the new version via the github UI and it will automatically kick off the
release pipeline.
