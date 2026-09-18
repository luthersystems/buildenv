GOLANG_VERSION=1.26.6
ALPINE_VERSION=3.24
GO_BINDATA_VERSION=3.1.3
GO_TESTSUM_VERSION=1.13.0
GOLANGCI_LINT_VERSION=2.11.4
BUF_VERSION=1.68.2
GO_SWAGGER_VERSION=0.33.2
GIT_LFS_VERSION=3.7.1
DOCKER_CLI_VERSION=29.6.1
DOCKER_COMPOSE_VERSION=5.2.0
AZCLI_VER=2.87.0
AWSCLI_VER=2.35.11
NODE_VERSION=20.19.3

# Transitive Go module pins for the from-source tool builds (see /scout-fix
# section C). Each clears a specific CVE in a dep bundled by golangci-lint,
# gotestsum, buf, go-swagger, git-lfs, docker/cli or docker-compose; the
# Dockerfiles take them as ARGs so a security bump is a one-line change here.
# Never pin lower than a sibling requires (x/mod pulls x/tools >= 0.49.0, which
# needs x/net >= 0.58.0 / x/crypto >= 0.55.0; grpc 1.83.2 needs x/net >= 0.58.0).
X_CRYPTO_VERSION=0.56.0
X_NET_VERSION=0.58.0
X_SYS_VERSION=0.47.0
X_MOD_VERSION=0.40.0
GRPC_VERSION=1.83.2
GO_ARCHIVE_VERSION=0.3.3
QUIC_GO_VERSION=0.59.1
