PROJECT_DIR=..
COMMON_MAKEFILE=${PROJECT_DIR}/common.mk
include ${COMMON_MAKEFILE}
CONFIG_MAKEFILE=${PROJECT_DIR}/common.config.mk
include ${CONFIG_MAKEFILE}

IMAGES= \
	luthersystems/build-api \
	luthersystems/build-go \
	luthersystems/build-go-alpine \
	luthersystems/build-godynamic \
	luthersystems/build-e2e \
	luthersystems/build-java \
	luthersystems/build-js \
	luthersystems/build-swaggercodegen \
	luthersystems/nginx-frontend \
	luthersystems/service-base-alpine
ALL_IMAGES=${IMAGES}

TAG_SUFFIX=
DOCKER_BUILDX_OPTS=$(if $(GIT_TAG),--push,)
PLATFORMS=linux/amd64,linux/arm64
# Extra flags appended to `docker buildx build`. CI sets this to wire up
# GitHub Actions layer caching (--cache-from/--cache-to type=gha).
BUILDX_CACHE_FLAGS ?=

# Supply-chain attestations (SBOM + SLSA provenance, mode=max). These satisfy
# Docker Scout's "supply chain attestation(s)" policy. Attestations only attach
# to images exported to a registry; the local docker exporter (--load) rejects
# them, so gate on GIT_TAG exactly like --push above (a local `make ... --load`
# build stays attestation-free and keeps working). On the per-arch publish
# build these attach to luthersystems/<img>:<ver>-<arch>; `make push-manifests`
# (buildx imagetools create) carries the attestation manifests into the
# combined multi-arch index. Verify post-publish with:
#   docker buildx imagetools inspect luthersystems/<img>:<ver> --format '{{json .}}'
# and confirm application/vnd.in-toto+json manifests exist per platform.
DOCKER_ATTEST_OPTS=$(if $(GIT_TAG),--provenance=mode=max --sbom=true,)

# do *NOT* delete intermediate artifacts!
.SECONDARY:

.PHONY:
IMAGE_DUMMYS := $(foreach I,$(IMAGES),$(call IMAGE_DUMMY,$I))
PUSH_DUMMYS := $(foreach I,$(ALL_IMAGES),$(call PUSH_DUMMY,$I))

.PHONY: default
default: ${IMAGE_DUMMYS}

.PHONY: docker-push-manifest
push-manifests: ${PUSH_DUMMYS}
	@

.PHONY: clean
clean:
	${RM} -rf _build

%: $(call IMAGE_DUMMY,luthersystems/%)
	@

$(call IMAGE_DUMMY,luthersystems/%): Dockerfile.% Makefile ${COMMON_MAKEFILE} ${CONFIG_MAKEFILE} $(call DUMMY_TARGET,deps,luthersystems/%)
	@echo "Building image $*"
	${DOCKER} buildx inspect --bootstrap
	${DOCKER} buildx build ${DOCKER_BUILDX_OPTS} ${DOCKER_ATTEST_OPTS} ${BUILDX_CACHE_FLAGS} \
		--platform ${PLATFORMS} \
		--progress plain \
		--build-arg GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION} \
		--build-arg NODE_VERSION=${NODE_VERSION} \
		--build-arg GOLANG_VERSION=${GOLANG_VERSION} \
		--build-arg ALPINE_VERSION=${ALPINE_VERSION} \
		--build-arg GO_BINDATA_VERSION=${GO_BINDATA_VERSION} \
		--build-arg GO_TESTSUM_VERSION=${GO_TESTSUM_VERSION} \
		--build-arg BUF_VERSION=${BUF_VERSION} \
		--build-arg GO_SWAGGER_VERSION=${GO_SWAGGER_VERSION} \
		--build-arg GIT_LFS_VERSION=${GIT_LFS_VERSION} \
		--build-arg DOCKER_CLI_VERSION=${DOCKER_CLI_VERSION} \
		--build-arg DOCKER_COMPOSE_VERSION=${DOCKER_COMPOSE_VERSION} \
		--build-arg AZCLI_VER=${AZCLI_VER} \
		--build-arg AWSCLI_VER=${AWSCLI_VER} \
		-t luthersystems/$*:${VERSION}${TAG_SUFFIX} \
		-f $< .
	${MKDIR_P} $(dir $@)
	${TOUCH} $@

# This wildcard target will define a default action for images with no binary
# dependencies.
$(call DUMMY_TARGET,deps,luthersystems/%):
	${MKDIR_P} $(dir $@)
	${TOUCH} $@

$(call DUMMY_TARGET,deps,luthersystems/build-api): build-api.mk
	@

$(call DUMMY_TARGET,deps,luthersystems/build-swaggercodegen): build-swaggercodegen.mk
	@

$(call PUSH_DUMMY,luthersystems/%):
	${DOCKER} buildx imagetools create \
		--tag luthersystems/$*:latest \
		luthersystems/$*:${VERSION}-arm64 \
		luthersystems/$*:${VERSION}-amd64
	${DOCKER} buildx imagetools create \
		--tag luthersystems/$*:${VERSION} \
		luthersystems/$*:${VERSION}-arm64 \
		luthersystems/$*:${VERSION}-amd64
