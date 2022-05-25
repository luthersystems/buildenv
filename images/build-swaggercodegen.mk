SWAGGER_CODEGEN_JAR=/opt/swagger-codegen-cli.jar
SWAGGER_INPUT_SPEC ?= oracle.swagger.json
SDK_OUTPUT_DIR ?= api
.PHONY: build
build:
	@echo "Building ng6 TypeScript SDK in ${PWD}"
	java -jar ${SWAGGER_CODEGEN_JAR} generate -i ${SWAGGER_INPUT_SPEC} -o ${SDK_OUTPUT_DIR} -l typescript-angular --additional-properties ngVersion=11.0.0,modelPropertyNaming=original
