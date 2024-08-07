PROJECT_DIR=..
COMMON_MAKEFILE=${PROJECT_DIR}/common.mk
include ${COMMON_MAKEFILE}
CONFIG_MAKEFILE=${PROJECT_DIR}/common.config.mk
include ${CONFIG_MAKEFILE}

IMAGES=luthersystems/build-go-alpine luthersystems/service-base-alpine luthersystems/build-api luthersystems/build-swaggercodegen luthersystems/nginx-frontend
MULTI_STAGE_IMAGES=luthersystems/build-go luthersystems/build-godynamic luthersystems/build-java luthersystems/build-js
ALL_IMAGES=${IMAGES} ${MULTI_STAGE_IMAGES}

TAG_SUFFIX=
DOCKER_BUILDX_OPTS=$(if $(GIT_TAG),--push,)
PLATFORMS=linux/amd64,linux/arm64

# do *NOT* delete intermediate artifacts!
.SECONDARY:

.PHONY:
IMAGE_DUMMYS := $(foreach I,$(IMAGES),$(call IMAGE_DUMMY,$I)) $(foreach I,$(MULTI_STAGE_IMAGES),$(call IMAGE_DUMMY,multi-${I}))
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

multi-%: $(call IMAGE_DUMMY,multi-luthersystems/%)
	@

$(call IMAGE_DUMMY,multi-luthersystems/%): Dockerfile.%.static %.mk $(call IMAGE_DUMMY,luthersystems/%)
	@

$(call IMAGE_DUMMY,luthersystems/%): Dockerfile.% Makefile ${COMMON_MAKEFILE} ${CONFIG_MAKEFILE} $(call DUMMY_TARGET,deps,luthersystems/%)
	@echo "Building image $*"
	${DOCKER} buildx inspect --bootstrap
	${DOCKER} buildx build ${DOCKER_BUILDX_OPTS} \
		--platform ${PLATFORMS} \
		--progress plain \
		--build-arg GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION} \
		--build-arg GOLANG_VERSION=${GOLANG_VERSION} \
		--build-arg ALPINE_VERSION=${ALPINE_VERSION} \
		--build-arg GO_BINDATA_VERSION=${GO_BINDATA_VERSION} \
		--build-arg GO_TESTSUM_VERSION=${GO_TESTSUM_VERSION} \
		--build-arg BUF_VERSION=${BUF_VERSION} \
		--build-arg GO_SWAGGER_VERSION=${GO_SWAGGER_VERSION} \
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

$(call DUMMY_TARGET,deps,luthersystems/build-go):
	@

$(call DUMMY_TARGET,deps,luthersystems/build-go-alpine):
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
