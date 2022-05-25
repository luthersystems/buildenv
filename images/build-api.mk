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
build: ${ARTIFACTS}
	@echo "Formating protos ${MODEL_PROTOS} ${SRV_PROTOS}"
	buf format -w
	@echo "Linting protos ${MODEL_PROTOS} ${SRV_PROTOS}"
	buf lint
	@echo "Building protos $@ ${VERSION}"
	buf generate
	swagger -q validate --stop-on-error ./srvpb/*/*.swagger.json
