DOCKER=docker
PYTHON=python3
PIP=pip3

# Default registry if not provided (can be overridden by CI environment)
REGISTRY ?= luthersystems

# Optional suffix (e.g. -amd64, -arm64) for multi-arch builds
TAG_SUFFIX ?=

# Target platform (CI will override to linux/arm64)
PLATFORM ?= linux/amd64

.PHONY: static
static: build
	@echo "Building Static Image: ${STATIC_IMAGE} for ${PLATFORM}"
	# Build the final runtime image for the requested architecture
	${DOCKER} buildx build --load \
		--platform ${PLATFORM} \
		--build-arg PYTHON_VERSION=${PYTHON_VERSION} \
		-t ${STATIC_IMAGE}:latest \
		-t ${STATIC_IMAGE}:${VERSION} \
		-f - . < /opt/Dockerfile.python.static

.PHONY: build
build:
	@echo "Setting up Python environment with uv..."
	uv sync --frozen

.PHONY: test
test:
	. .venv/bin/activate && pytest src/

.PHONY: lint
lint:
	. .venv/bin/activate && ruff check src/ && ruff format --check src/

.PHONY: push
push:
	@echo "Pushing ${REGISTRY}/${STATIC_IMAGE}:${VERSION}${TAG_SUFFIX}"
	${DOCKER} tag ${STATIC_IMAGE}:${VERSION} ${REGISTRY}/${STATIC_IMAGE}:${VERSION}${TAG_SUFFIX}
	${DOCKER} push ${REGISTRY}/${STATIC_IMAGE}:${VERSION}${TAG_SUFFIX}
