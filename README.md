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

## Image security policies

The published images are scanned against Docker Scout policies. Two policy
requirements affect how downstream repos consume these images:

### Supply-chain attestations

Every published image carries SBOM + SLSA provenance attestations. These are
attached during the per-arch `buildx build` (gated to tag/push builds in
`images/Makefile`) and the `verify-attestations` job in `publish.yml` fails the
release if any platform is missing either predicate. No action is required
downstream — this is purely a property of the published image.

### Non-root default user (downstream coordination required)

To satisfy Docker Scout's "no default non-root user" policy, the build images
default to a non-root `build` user (uid 1000):

- `service-base-alpine` runs as `nobody` (the prod runtime image).
- `build-api` defaults to `build`; its consumers already run it with
  `-u $(id -u):$(id -g)`, which overrides the default and keeps working.
- `build-go-alpine` defaults to `build`.

**`build-go-alpine` is also used as a `FROM` base in downstream multi-stage
builds** (e.g. `ui-core/Dockerfile-go`, and any repo using the shared
`common.go.mk` + `Dockerfile-go` pattern). Those build stages inherit the
non-root `USER`, but they write **root-owned BuildKit cache mounts**
(`--mount=type=cache,target=/go/pkg/mod` for `go mod download`,
`/root/.cache/go-build`) and `COPY` root-owned sources, so they will fail with
permission-denied unless the build stage re-asserts root:

```dockerfile
FROM $BUILD_IMAGE AS build
USER root          # required: build stage needs to write the root-owned cache mounts
```

The prod stage (`FROM service-base-alpine`) is unaffected and still runs as
`nobody`. **Land this one-line change in every consumer before bumping the
`BUILDENV_TAG` those repos pin to a release carrying the non-root default**, or
their builds will break.
