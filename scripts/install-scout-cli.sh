#!/usr/bin/env bash
# Install a PINNED, checksum-verified Docker Scout CLI plugin (#120).
#
# Replaces `curl …/docker/scout-cli/main/install.sh | sh`, which ran an
# unpinned script from a moving branch inside the fail-closed CVE gates and the
# release pipeline: an upstream change on `main` could take every gate down at
# once, and a compromised `main` would run arbitrary shell in the release path.
#
# The version and the per-arch SHA-256 of the release tarball live in ONE place,
# common.config.mk (SCOUT_CLI_VERSION, SCOUT_CLI_SHA256_LINUX_AMD64/ARM64). To
# bump: take the new tag from https://github.com/docker/scout-cli/releases, and
# copy the two linux sums from that release's docker-scout_<ver>_checksums.txt.
# Dependabot cannot track this (it is not an Action), so the bump is manual,
# like every other tool version in common.config.mk.
#
# Usage: install-scout-cli.sh            # installs into ~/.docker/cli-plugins
#        DOCKER_CONFIG=/x install-scout-cli.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/common.config.mk"

read_cfg() { sed -n "s/^$1=//p" "$CONFIG" | head -1; }

VERSION="$(read_cfg SCOUT_CLI_VERSION)"
if [[ -z "$VERSION" ]]; then
  echo "error: SCOUT_CLI_VERSION not set in $CONFIG" >&2
  exit 1
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  *) echo "error: unsupported OS $(uname -s) (CI runs on Linux)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

ARCH_UPPER="$(echo "$arch" | tr '[:lower:]' '[:upper:]')"
WANT="$(read_cfg "SCOUT_CLI_SHA256_LINUX_${ARCH_UPPER}")"
if [[ -z "$WANT" ]]; then
  echo "error: SCOUT_CLI_SHA256_LINUX_${ARCH_UPPER} not set in $CONFIG" >&2
  exit 1
fi

TARBALL="docker-scout_${VERSION}_${os}_${arch}.tar.gz"
URL="https://github.com/docker/scout-cli/releases/download/v${VERSION}/${TARBALL}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 --retry-all-errors -o "$tmp/$TARBALL" "$URL"

GOT="$(sha256sum "$tmp/$TARBALL" | cut -d' ' -f1)"
if [[ "$GOT" != "$WANT" ]]; then
  echo "error: checksum mismatch for $TARBALL: want $WANT, got $GOT" >&2
  exit 1
fi

tar --no-same-owner -xzf "$tmp/$TARBALL" -C "$tmp" docker-scout

PLUGIN_DIR="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
mkdir -p "$PLUGIN_DIR"
install -m 0755 "$tmp/docker-scout" "$PLUGIN_DIR/docker-scout"

echo "Installed docker-scout v${VERSION} (${os}/${arch}, sha256 verified) into $PLUGIN_DIR"
