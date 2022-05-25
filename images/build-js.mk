DOCKER=docker

.PHONY: static
static: build
	@echo "Static ${STATIC_IMAGE}"
	${DOCKER} build \
		-t ${STATIC_IMAGE}:latest \
		-t ${STATIC_IMAGE}:${VERSION} \
		-f -  . < /opt/Dockerfile.js.static

.PHONY: build
build:
	@echo "Building in ${PWD}"
	npm --allow-same-version version ${VERSION}
	npm install --verbose --prefer-offline
	npm rebuild node-sass
	npm run build
