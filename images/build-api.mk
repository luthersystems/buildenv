# IMPORTANT: this container expects the directories to be in specific structure
# and the root project to vendor grpc-gateway (see parternloan for example).
#
# api/
#   pb/      - protobuf files
#   srvpb/   - grpc services file
#   swagger/ - output swagger json, along with add_auth_filter.jq that post
#              processes swagger json.

MODEL_PROTOS=$(wildcard pb/*/*.proto)
SRV_PROTOS=$(wildcard srvpb/*/*.proto)

ARTIFACTS=${MODEL_PROTOS} ${SRV_PROTOS}

.PHONY: build
build: format lint proto validate-swagger

.PHONY: format
format:
	@echo "Formating protos ${MODEL_PROTOS} ${SRV_PROTOS}"
	buf format -w

.PHONY: lint
lint:
	@echo "Linting protos ${MODEL_PROTOS} ${SRV_PROTOS}"
	buf lint

.PHONY: proto
proto:
	@echo "Building protos $@ ${VERSION}"
	buf generate

.PHONY: validate-swagger
validate-swagger:
	@echo "Validating generated swagger files"
	@SWAGGER_FILES=$$(find ./srvpb -type f -name '*.swagger.json'); \
	if [ -n "$$SWAGGER_FILES" ]; then \
		swagger -q validate --stop-on-error $$SWAGGER_FILES; \
	else \
		echo "No swagger files found. Skipping validation."; \
	fi
