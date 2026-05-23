DOCKER=docker

# Override to pin the nginx-frontend base image (e.g. to a specific buildenv
# release). Defaults to `latest`, which always matches the most recent
# buildenv tag published to Docker Hub.
NGINX_FRONTEND_VERSION ?= latest

.PHONY: static
static: build
	@echo "Static ${STATIC_IMAGE}"
	${DOCKER} build \
		--build-arg NGINX_FRONTEND_VERSION=${NGINX_FRONTEND_VERSION} \
		-t ${STATIC_IMAGE}:latest \
		-t ${STATIC_IMAGE}:${VERSION} \
		-f -  . < /opt/Dockerfile.js.static

.PHONY: build
build:
	@echo "Building in ${PWD}"
	npm install --verbose --prefer-offline
	npm rebuild node-sass
	npm run build
