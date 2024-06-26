GO_TEST_FLAGS ?= -cover
GO_BUILD_TAGS ?= netgo,timetzdata
GO_BUILD_EXTRA_FLAGS ?= -a

GO_BUILD_FLAGS=-installsuffix ${GO_BUILD_TAGS} -tags ${GO_BUILD_TAGS} -buildvcs=false
GO_LD_FLAGS=-X $(shell go list -buildvcs=false)/version.Version=${VERSION} -extldflags "-static"

DOCKER=docker

.PHONY: static
static: build
	@echo "Static ${STATIC_IMAGE}"
	bash -c 'while read LINE; do if [ "$$LINE" == "{}" ]; then cat ./fragment.txt; else echo "$$LINE"; fi; done' </opt/Dockerfile.goextra.static >/tmp/Dockerfile.goextra.static
	cat /tmp/Dockerfile.goextra.static
	${DOCKER} build \
		--build-arg BIN=$(notdir ${BIN}) \
		-t ${STATIC_IMAGE}:latest \
		-t ${STATIC_IMAGE}:${VERSION} \
		-f - . </tmp/Dockerfile.goextra.static

.PHONY: build
build:
	@echo "Building BIN=\"${BIN}\" VERSION=\"${VERSION}\""
	mkdir -p build/bin
	go env
	# build static binary with CGO extensions enabled and libtool
	go build ${GO_BUILD_EXTRA_FLAGS}  ${GO_BUILD_FLAGS} -ldflags '${GO_LD_FLAGS}' -o ${BIN}

.PHONY: test
test:
	@echo "Test"
	go test ${GO_TEST_FLAGS} ${GO_BUILD_FLAGS} ./...
