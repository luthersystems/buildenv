PROJECT_DIR=..
COMMON_MAKEFILE=${PROJECT_DIR}/common.mk
include ${COMMON_MAKEFILE}
CONFIG_MAKEFILE=${PROJECT_DIR}/common.config.mk
include ${CONFIG_MAKEFILE}

IMAGES= \
	luthersystems/awscli \
	luthersystems/build-harden \
	luthersystems/build-api \
	luthersystems/build-go \
	luthersystems/build-go-alpine \
	luthersystems/build-godynamic \
	luthersystems/build-e2e \
	luthersystems/build-java \
	luthersystems/build-js \
	luthersystems/build-swaggercodegen \
	luthersystems/dind \
	luthersystems/fabric-tools \
	$(addprefix luthersystems/,${FABRIC_WRAPPERS}) \
	luthersystems/nginx-frontend \
	luthersystems/service-base-alpine
ALL_IMAGES=${IMAGES}

# The Fabric chaincode images, one per Fabric minor, built from one Dockerfile
# per kind (Dockerfile.fabric-baseos, Dockerfile.fabric-ccenv). A peer chooses
# the image by its Fabric version, and each minor has its own base (and, for
# ccenv, its own Go), so one tag per minor lets a peer swap
# hyperledger/fabric-baseos:2.2 for luthersystems/fabric-baseos:2.2.
# The target fabric-baseos-2.2 builds luthersystems/fabric-baseos with tags
# 2.2-<version>[-<arch>]. There is no moving tag (no latest, no bare 2.2): a
# peer runs these images in production, and an automation-cut patch release
# must not reach a peer that has not chosen it, so peers pin
# <minor>-<version>. There is no fabric-baseos-2.5: that image has no CA
# bundle to harden.
FABRIC_WRAPPERS=fabric-baseos-2.2 fabric-baseos-2.4 fabric-ccenv-2.2 fabric-ccenv-2.4 fabric-ccenv-2.5
# Upstream publishes 2.2 and 2.4 for amd64 only. Keep the arm64 excludes in
# .github/workflows/build.yml and publish.yml in step with this list.
ARCHES_fabric-baseos-2.2=amd64
ARCHES_fabric-baseos-2.4=amd64
ARCHES_fabric-ccenv-2.2=amd64
ARCHES_fabric-ccenv-2.4=amd64

comma=,
is_fabric_wrapper=$(filter $1,${FABRIC_WRAPPERS})
fabric_minor=$(lastword $(subst -, ,$1))
# repo: the Docker Hub repository of an image target (fabric-baseos-2.2 ->
# fabric-baseos; any other target is its own repository).
repo=$(if $(call is_fabric_wrapper,$1),$(1:%-$(call fabric_minor,$1)=%),$1)
# ref IMAGE,TAG: the reference of an image target at a tag. For a Fabric
# wrapper the tag is prefixed with the minor.
ref=luthersystems/$(call repo,$1):$(if $(call is_fabric_wrapper,$1),$(call fabric_minor,$1)-)$2
arches=$(or ${ARCHES_$1},arm64 amd64)
# The platforms to build: PLATFORMS, less those upstream does not publish.
platforms=$(subst $() ,$(comma),$(strip $(filter $(addprefix linux/,$(call arches,$1)),$(subst $(comma), ,${PLATFORMS}))))
# A wrapper with no pinned version must not build: the Dockerfile's ARG
# default would give it another minor's base under this minor's tag.
fabric_version=$(if $(call is_fabric_wrapper,$1),$(or ${FABRIC_$(subst .,_,$(call fabric_minor,$1))_VERSION},$(error $1: set FABRIC_$(subst .,_,$(call fabric_minor,$1))_VERSION in common.config.mk)))

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
# The default build skips an image that upstream does not publish for
# PLATFORMS (the Fabric 2.2 and 2.4 wrappers on an arm64-only build), so an
# all-images build on an arm64 host still builds every other image. Naming
# such an image fails, below.
IMAGE_DUMMYS := $(foreach I,$(IMAGES),$(if $(call platforms,$(I:luthersystems/%=%)),$(call IMAGE_DUMMY,$I)))
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

# The kinds of the Fabric wrappers are not images: each Fabric minor is.
# Without this, `%:` would build them from the Dockerfile's ARG default.
.PHONY: fabric-baseos fabric-ccenv
fabric-baseos fabric-ccenv:
	@echo "$@ has one image per Fabric minor; build one of: $(filter $@-%,${FABRIC_WRAPPERS})" >&2
	@exit 1

# Print the reference that a build of an image target is tagged with, for CI
# (the build action checks the image it built): make -s print-ref-<image>.
print-ref-%:
	@echo $(call ref,$*,${VERSION}${TAG_SUFFIX})

# Every image runs the build-harden kit, so a change to it rebuilds them all.
HARDEN_FILES := $(shell find harden -type f)

# Secondary expansion lets a Fabric wrapper target name its kind's Dockerfile.
.SECONDEXPANSION:
$(call IMAGE_DUMMY,luthersystems/%): Dockerfile.$$(call repo,$$*) ${HARDEN_FILES} Makefile ${COMMON_MAKEFILE} ${CONFIG_MAKEFILE} $(call DUMMY_TARGET,deps,luthersystems/%)
	@echo "Building image $*"
	$(if $(call platforms,$*),,$(error $* is not published upstream for ${PLATFORMS}; it is built for $(call arches,$*)))
	${DOCKER} buildx inspect --bootstrap
	${DOCKER} buildx build ${DOCKER_BUILDX_OPTS} ${DOCKER_ATTEST_OPTS} ${BUILDX_CACHE_FLAGS} \
		--platform $(call platforms,$*) \
		--progress plain \
		--build-arg GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION} \
		--build-arg NODE_VERSION=${NODE_VERSION} \
		--build-arg NGINX_VERSION=${NGINX_VERSION} \
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
		--build-arg DIND_VERSION=${DIND_VERSION} \
		--build-arg FABRIC_TOOLS_VERSION=${FABRIC_TOOLS_VERSION} \
		$(if $(call fabric_version,$*),--build-arg FABRIC_VERSION=$(call fabric_version,$*)) \
		-t $(call ref,$*,${VERSION}${TAG_SUFFIX}) \
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
	$(if $(call is_fabric_wrapper,$*),,${DOCKER} buildx imagetools create \
		--tag $(call ref,$*,latest) \
		$(foreach A,$(call arches,$*),$(call ref,$*,${VERSION}-$A)))
	${DOCKER} buildx imagetools create \
		--tag $(call ref,$*,${VERSION}) \
		$(foreach A,$(call arches,$*),$(call ref,$*,${VERSION}-$A))
