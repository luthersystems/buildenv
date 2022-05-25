GO_TEST_FLAGS ?= -cover
GO_BUILD_TAGS ?= netgo,cgo,timetzdata

GO_BUILD_FLAGS=-installsuffix ${GO_BUILD_TAGS} -tags ${GO_BUILD_TAGS}
GO_LD_FLAGS=-X $(shell go list)/version.Version=${VERSION} -extldflags "-static"

# Try to inherit TINI_VERSION from the build container env
TINI_VERSION?=0.19.0

DOCKER=docker

.PHONY: static
static: build
	@echo "Static ${STATIC_IMAGE}"
	${DOCKER} build \
		--build-arg BIN=$(notdir ${BIN}) \
		--build-arg TINI_VERSION=${TINI_VERSION} \
		-t ${STATIC_IMAGE}:latest \
		-t ${STATIC_IMAGE}:${VERSION} \
		-f -  . < /opt/Dockerfile.go.static

.PHONY: build
build:
	@echo "Building BIN=\"${BIN}\" VERSION=\"${VERSION}\""
	mkdir -p build/bin
	go env
	# build static binary with CGO extensions enabled and libtool
	CGO_ENABLED=1 GOOS=linux go build -a ${GO_BUILD_FLAGS} -ldflags '${GO_LD_FLAGS}' -o ${BIN}
	chown ${DOCKER_CHOWN_USER}:${DOCKER_CHOWN_GROUP} build/bin

.PHONY: test
test:
	@echo "Test"
	CGO_LDFLAGS_ALLOW=-I/usr/local/share/libtool go test ${GO_TEST_FLAGS} ${GO_BUILD_FLAGS} ./...
