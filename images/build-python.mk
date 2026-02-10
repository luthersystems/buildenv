DOCKER=docker
PYTHON=python3
PIP=pip3

# Default registry if not provided (can be overridden by CI environment)
REGISTRY ?= luthersystems
# Optional suffix (e.g. -amd64, -arm64) for multi-arch builds
TAG_SUFFIX ?=

.PHONY: static
static: build
	@echo "Building Static Image: ${STATIC_IMAGE}"
	# Uses the static Dockerfile template to build the final runtime image
	${DOCKER} buildx build --load \
		--build-arg PYTHON_VERSION=${PYTHON_VERSION} \
		-t ${STATIC_IMAGE}:latest \
		-t ${STATIC_IMAGE}:${VERSION} \
		-f - . < /opt/Dockerfile.python-agent.static

.PHONY: build
build:
	@echo "Setting up Python environment..."
	# Create virtualenv and install deps
	${PYTHON} -m venv .venv
	. .venv/bin/activate && ${PIP} install --no-cache-dir -r requirements.txt

.PHONY: test
test:
	. .venv/bin/activate && pytest src/

.PHONY: lint
lint:
	. .venv/bin/activate && flake8 src/ && black --check src/

.PHONY: push
push:
	@echo "Pushing ${REGISTRY}/${STATIC_IMAGE}:${VERSION}${TAG_SUFFIX}"
	${DOCKER} tag ${STATIC_IMAGE}:${VERSION} ${REGISTRY}/${STATIC_IMAGE}:${VERSION}${TAG_SUFFIX}
	${DOCKER} push ${REGISTRY}/${STATIC_IMAGE}:${VERSION}${TAG_SUFFIX}
