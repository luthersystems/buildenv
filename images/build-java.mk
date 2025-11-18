DOCKER=docker

.PHONY: static
static:
	@echo "Static ${STATIC_IMAGE}"
	${DOCKER} buildx build --load \
		--build-arg BIN=$(notdir ${BIN}) \
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
