GOLANG_VERSION=1.27.3
ALPINE_VERSION=3.24
GO_BINDATA_VERSION=3.1.3
GO_TESTSUM_VERSION=1.13.0
GOLANGCI_LINT_VERSION=2.13.2
BUF_VERSION=1.68.2
GO_SWAGGER_VERSION=0.33.2
GIT_LFS_VERSION=3.7.1
DOCKER_CLI_VERSION=29.6.1
DOCKER_COMPOSE_VERSION=5.2.0
AZCLI_VER=2.91.0
AWSCLI_VER=2.35.11
# dind base: docker:${DIND_VERSION}-dind. Not Docker 29: see
# images/Dockerfile.dind
DIND_VERSION=28.5.2
# fabric-tools base: hyperledger/fabric-tools:${FABRIC_TOOLS_VERSION} (see
# images/Dockerfile.fabric-tools). The fabric-snapshot-archiver base.
FABRIC_TOOLS_VERSION=2.5.6
# fabric-baseos and fabric-ccenv bases, one per Fabric minor:
# hyperledger/fabric-{baseos,ccenv}:${FABRIC_<minor>_VERSION} (see
# images/Dockerfile.fabric-baseos and images/Dockerfile.fabric-ccenv). 2.2 and
# 2.4 are the last releases of those minors, amd64 only upstream.
FABRIC_2_2_VERSION=2.2.15
FABRIC_2_4_VERSION=2.4.9
FABRIC_2_5_VERSION=2.5.16
NODE_VERSION=24.22.1
# nginx-frontend base: nginxinc/nginx-unprivileged:${NGINX_VERSION}-alpine${ALPINE_VERSION}
NGINX_VERSION=1.30
# Docker Scout CLI used by the CI gates (scripts/install-scout-cli.sh). Bump the
# version and both sums together, from the release's docker-scout_<ver>_checksums.txt.
SCOUT_CLI_VERSION=1.26.0
SCOUT_CLI_SHA256_LINUX_AMD64=47daa9ac442816316c65389f516b847146bb9f45e8d6afdcbb9ce835c4e138bd
SCOUT_CLI_SHA256_LINUX_ARM64=34282a50d6787eec46e44a377a1ed9e70342adf078135cca8617c9199852725c

# --- Go module security pins -------------------------------------------------
# The from-source Go tools in the build images (gotestsum, golangci-lint, buf,
# go-swagger, git-lfs, docker CLI, docker compose) bundle transitive modules at
# vulnerable versions. Each `go get` raises them to the versions below. Every
# GO_PIN_* reaches every image build as a build arg (images/Makefile), and
# `make check-go-pins` fails on a version hard-coded in a Dockerfile.
#
# To clear a CVE in one of these modules, bump its value here. A new module
# needs a GO_PIN_* line here, an `ARG GO_PIN_*` and an `@v${GO_PIN_*}` in the
# Dockerfiles that build the affected tool. Keep the x/ family consistent: a new
# x/net can raise the floor of x/crypto, x/sys and x/text (MVS refuses a
# downgrade, so the go get fails loudly if a floor is missed).
#
# golang.org/x/crypto: CVE-2026-56854 / CVE-2026-78662 / CVE-2026-56855 (fixed
# in 0.56.0); 0.58.0 is the floor x/net 0.62.0 requires.
GO_PIN_X_CRYPTO=0.58.0
# golang.org/x/mod: CVE-2026-56864 / CVE-2026-56865 (via x/tools).
GO_PIN_X_MOD=0.41.0
# golang.org/x/net: CVE-2026-46600 (0.56.0); CVE-2026-78663 (CRITICAL),
# CVE-2026-78659, CVE-2026-78660, CVE-2026-78669 (0.60.0, #144);
# CVE-2026-78661 (0.62.0, #187).
GO_PIN_X_NET=0.62.0
# golang.org/x/sys: CVE-2026-39824; 0.49.0 is the floor x/net 0.62.0 requires.
GO_PIN_X_SYS=0.49.0
# golang.org/x/text: CVE-2026-56851 (0.41.0); 0.43.0 is the floor x/net 0.62.0
# requires.
GO_PIN_X_TEXT=0.43.0
# google.golang.org/grpc (docker CLI, compose): GHSA-hrxh-6v49-42gf,
# CVE-2026-84304, CVE-2026-84445 (fixed in 1.83.2). Drop once docker/cli and
# compose require it.
GO_PIN_GRPC=1.83.2
# github.com/go-jose/go-jose/v4 (docker CLI): CVE-2026-116587 (4.1.6, #180).
# Drop once docker/cli requires it.
GO_PIN_GO_JOSE=4.1.6
# github.com/quic-go/quic-go (buf): CVE-2026-40898.
GO_PIN_QUIC_GO=0.59.1
# github.com/klauspost/compress (buf): CVE-2026-63209 (1.18.7).
GO_PIN_KLAUSPOST_COMPRESS=1.18.7
# github.com/moby/go-archive (compose): CVE-2026-17106 (0.3.0); 0.3.3 matches
# the docker CLI build.
GO_PIN_MOBY_GO_ARCHIVE=0.3.3
# github.com/containerd/containerd/v2 (compose): CVE-2026-95837 (2.2.7).
GO_PIN_CONTAINERD=2.2.7
