#!/usr/bin/env bash
#
# Retirement check for the from-source Docker CLI build.
#
# build-go, build-godynamic, build-java and build-js compile the Docker CLI
# from source instead of installing the published static tarball. That is a
# workaround, not a preference: Docker builds its published CLI with whatever
# Go release it happened to use, and in August 2026 every published artifact
# (the static tarballs AND the official docker:*-cli images, up to and
# including 29.7.2 / :cli) was stamped go1.26.5 or older, while six Go stdlib
# CVEs behind the #115 grade-A drift are only fixed in go1.26.6. No
# DOCKER_CLI_VERSION value cleared them, so the source build was the only way.
#
# The risk with that workaround is not that it breaks -- it is that it quietly
# becomes permanent. This script is the exit condition. It reads the published
# CLI's embedded Go stamp and compares it to the GOLANG_VERSION this repo pins.
# Once Docker ships a CLI built with a Go at least as new as ours, the source
# build has no remaining justification and the Dockerfiles should go back to
# the tarball (simpler, one fewer builder stage, faster image builds).
#
# Report-only by default so it can ride the daily drift watch without failing
# it; --strict exits 1 when the source build is retireable, for use as a gate.
#
# Usage:
#   docker-cli-source-build-check.sh            report only (always exits 0)
#   docker-cli-source-build-check.sh --strict    exit 1 if retireable
#
# Reads GOLANG_VERSION and DOCKER_CLI_VERSION from common.config.mk.

set -euo pipefail

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/common.config.mk"

read_cfg() { sed -n "s/^$1=//p" "$CONFIG" | head -1; }

GOLANG_VERSION="$(read_cfg GOLANG_VERSION)"
DOCKER_CLI_VERSION="$(read_cfg DOCKER_CLI_VERSION)"

if [[ -z "$GOLANG_VERSION" || -z "$DOCKER_CLI_VERSION" ]]; then
  echo "::warning::could not read GOLANG_VERSION/DOCKER_CLI_VERSION from $CONFIG; skipping"
  exit 0
fi

BASE="https://download.docker.com/linux/static/stable/x86_64"

# Newest published static release, so the check also notices a Docker release
# newer than our pin that has already moved to a suitable Go.
NEWEST="$(curl -fsSL "$BASE/" 2>/dev/null \
  | grep -o 'docker-[0-9][0-9.]*\.tgz' \
  | sed 's/^docker-//; s/\.tgz$//' \
  | sort -V | tail -1 || true)"

# Embedded Go build stamp, without needing a Go toolchain. Verified to match
# `go version -m` on the 29.6.1 (go1.26.4) and 29.7.2 (go1.26.5) binaries.
published_go() {
  local ver="$1" tmp
  tmp="$(mktemp -d)"
  if ! curl -fsSL "$BASE/docker-${ver}.tgz" 2>/dev/null | tar -xz -C "$tmp" docker/docker 2>/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  grep -a -o -m1 'go1\.[0-9]\{1,\}\.[0-9]\{1,\}' "$tmp/docker/docker" | head -1
  rm -rf "$tmp"
}

# True when $1 >= $2 under version ordering.
at_least() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

echo "pinned GOLANG_VERSION:     $GOLANG_VERSION"
echo "pinned DOCKER_CLI_VERSION: $DOCKER_CLI_VERSION"
echo "newest published CLI:      ${NEWEST:-<unknown>}"
echo

retireable=0
for ver in "$DOCKER_CLI_VERSION" "$NEWEST"; do
  [[ -z "$ver" ]] && continue
  stamp="$(published_go "$ver" || true)"
  if [[ -z "$stamp" ]]; then
    echo "  docker $ver: could not read Go stamp (skipped)"
    continue
  fi
  pub="${stamp#go}"
  if at_least "$pub" "$GOLANG_VERSION"; then
    echo "  docker $ver: $stamp  >= go$GOLANG_VERSION  <-- RETIREABLE"
    retireable=1
  else
    echo "  docker $ver: $stamp  <  go$GOLANG_VERSION  (source build still required)"
  fi
done

echo
if [[ "$retireable" == "1" ]]; then
  cat <<'MSG'
::notice::Docker now publishes a CLI built with a Go at least as new as this
repo's GOLANG_VERSION. The from-source Docker CLI build in
images/Dockerfile.build-{go,godynamic,java,js} is no longer needed: replace the
builder-stage `go get`/`go build` + `COPY --from=... /go/bin/docker` with the
original `curl … download.docker.com/…/docker-${DOCKER_CLI_VERSION}.tgz` install
(bumping DOCKER_CLI_VERSION to the release that carries the newer Go), and drop
the now-unused docker-cli-builder stages from build-java and build-js.
MSG
  [[ "$STRICT" == "1" ]] && exit 1
else
  echo "Source build still justified — no published Docker CLI reaches go${GOLANG_VERSION}."
fi
exit 0
