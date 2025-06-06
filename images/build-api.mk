# IMPORTANT:
#
# This Makefile supports both default and flexible directory structures.
#
# By default, it expects:
#   pb/      - shared protobuf message definitions
#   srvpb/   - gRPC service definitions
#   swagger/ - output swagger JSON files (optional, can be validated)
#
# If submodules exist, they should live under:
#   submodules/
#
# and be referenced in the parent buf.yaml
#
# Submodules are scanned only if INCLUDE_SUBMODULES=true is specified.
# All directory paths (MODEL_PROTO_PATH, SRV_PROTO_PATH, SWAGGER_PATH, etc.)
# can be overridden to support different client layouts.

MODEL_PROTO_PATH ?= pb
SRV_PROTO_PATH ?= srvpb
SWAGGER_VALIDATION_PATH ?= srvpb
INCLUDE_SUBMODULES ?= false

MODEL_PROTOS := $(wildcard ${MODEL_PROTO_PATH}/*/*.proto)
SRV_PROTOS := $(wildcard ${SRV_PROTO_PATH}/*/*.proto)
SUBMODULE_PROTOS := $(if $(filter true,${INCLUDE_SUBMODULES}),$(shell find submodules -type f -name '*.proto' 2>/dev/null),)

ARTIFACTS := ${MODEL_PROTOS} ${SRV_PROTOS} ${SUBMODULE_PROTOS}

$(info MODEL_PROTOS: ${MODEL_PROTOS})
$(info SRV_PROTOS: ${SRV_PROTOS})
$(info SUBMODULE_PROTOS: ${SUBMODULE_PROTOS})
$(info ARTIFACTS: ${ARTIFACTS})

.PHONY: build
build: validate-swagger ${ARTIFACTS}

.PHONY: format
format:
	@echo "Formatting protos: ${MODEL_PROTOS} ${SRV_PROTOS} ${SUBMODULE_PROTOS}"
	buf format -w

.PHONY: lint
lint:
	@echo "Linting protos: ${MODEL_PROTOS} ${SRV_PROTOS} ${SUBMODULE_PROTOS}"
	buf lint

.PHONY: gen
gen:
	@echo "Generating code from protos"
	buf generate

.PHONY: validate-swagger
validate-swagger:
	@echo "Validating swagger files"
	@SWAGGER_FILES=$$(find ${SWAGGER_VALIDATION_PATH} -type f -name '*.swagger.json'); \
	if [ -n "$$SWAGGER_FILES" ]; then \
		echo "Found swagger files: $$SWAGGER_FILES"; \
		if swagger -q validate --stop-on-error $$SWAGGER_FILES; then \
			echo "✅ Swagger validation passed."; \
		else \
			echo "❌ Swagger validation failed."; \
			exit 1; \
		fi \
	else \
		echo "No swagger files found, skipping validation."; \
	fi
