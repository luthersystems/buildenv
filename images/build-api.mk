# Default paths if not provided
SWAGGER_VALIDATION_PATH ?= .
PROTO_PATH ?= .

.PHONY: validate-swagger
validate-swagger:
	@echo "Validating swagger files"
	@echo "Current directory: $(PWD)"
	@echo "Looking for swagger files in: $(SWAGGER_VALIDATION_PATH)"
	@SWAGGER_FILES=$$(find $(SWAGGER_VALIDATION_PATH) -type f -name "*.swagger.json"); \
	echo "Found swagger files: $$SWAGGER_FILES"; \
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

.PHONY: build
build: gen validate-swagger

.PHONY: gen
gen:
	@ARTIFACTS=$$(find $(PROTO_PATH) -type f -name "*.proto"); \
	echo "Formating protos $$ARTIFACTS"; \
	buf format -w; \
	echo "Linting protos $$ARTIFACTS"; \
	buf lint; \
	echo "Building protos $@ ${VERSION}"; \
	buf generate