DOCKER=docker

# Try to inherit TINI_VERSION from the build container env
TINI_VERSION?=0.19.0

.PHONY: static
static:
	@echo "Static ${STATIC_IMAGE}"
	${DOCKER} build \
		--build-arg BIN=$(notdir ${BIN}) \
		--build-arg TINI_VERSION=${TINI_VERSION} \
		-t ${STATIC_IMAGE}:latest \
		-t ${STATIC_IMAGE}:${VERSION} \
		-f -  . < /opt/Dockerfile.java.static

.PHONY: build
build:
	@echo "Building BIN=\"${BIN}\" VERSION=\"${VERSION}\" in ${PWD}"
	mvn versions:set -DnewVersion=${VERSION}
	mvn package -Dmaven.test.skip=true

.PHONY: protos
protos:
	@echo "Generating protos"
	mvn protobuf:compile
