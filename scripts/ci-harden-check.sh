#!/usr/bin/env bash
# Run the build-harden image check (images/harden/check/image.sh) on one
# image that CI built, for one platform.
#
# Why here and not in the workflow: the check needs keytool and certutil on
# the host for an image with a Java keystore or an NSS database, and the
# build-harden image itself is the kit (it holds the listed certificates on
# purpose), so it gets a check of its own. CLAUDE.md rule 5 keeps that logic
# out of YAML.
#
# Usage: ci-harden-check.sh IMAGE_NAME REF PLATFORM
#   IMAGE_NAME  the buildenv image, such as build-go
#   REF         the image reference to check (a local --load tag on a PR,
#               the pushed tag on a release)
#   PLATFORM    such as linux/arm64
set -euo pipefail

name=${1:?usage: ci-harden-check.sh IMAGE_NAME REF PLATFORM}
ref=${2:?}
platform=${3:?}
kit=$(cd "$(dirname "${BASH_SOURCE[0]}")/../images/harden" && pwd)

if [ "$name" = build-harden ]; then
	# The kit image: it must hold the kit exactly as committed.
	work=$(mktemp -d)
	cid=$(docker create --platform "$platform" "$ref" /nonexistent)
	trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
	docker export "$cid" | tar -x -C "$work"
	diff -r "$kit" "$work/harden"
	echo "OK: $ref holds the build-harden kit"
	exit 0
fi

need=()
command -v openssl >/dev/null || need+=(openssl)
command -v keytool >/dev/null || need+=(default-jre-headless)
command -v certutil >/dev/null || need+=(libnss3-tools)
if [ "${#need[@]}" -gt 0 ]; then
	sudo apt-get update -qq
	sudo apt-get install -y -qq --no-install-recommends "${need[@]}" >/dev/null
fi

bash "$kit/check/image.sh" --platform "$platform" "$ref"
