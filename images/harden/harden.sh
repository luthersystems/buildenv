#!/bin/sh
# Harden a container image: run every policy module of the build-harden kit.
#
# Why: a policy such as "trust no CA whose key leaked" must hold in every image
# we ship, whatever its base (Alpine, Debian, Ubuntu, Amazon Linux) and
# architecture. One kit, with the policy kept as data, means the next incident
# is a change to a data file and a tag bump in each repo, not a new script per
# repo (CVE-2026-111943 needed a re-vendored copy in five repos).
#
# Run it as root, as the last step of the final stage that installs or
# upgrades packages, from a read-only bind mount, so no kit file stays in the
# image:
#
#   FROM luthersystems/build-harden:<version>@sha256:<digest> AS harden
#   ...
#   RUN --mount=type=bind,from=harden,source=/harden,target=/harden \
#       sh /harden/harden.sh
#
# It needs only /bin/sh and the tools every base image has (awk, grep, sed,
# find, base64, sha256sum); it ships no binaries, so it runs the same on amd64
# and arm64. A module that cannot apply its policy fails the build: an image
# that cannot be hardened must not pass as hardened.
#
# HARDEN_MODULES (optional) is a space-separated list of the modules to run;
# by default every module in modules/ runs, in name order.
set -eu

HARDEN_DIR=$(cd "$(dirname "$0")" && pwd)
export HARDEN_DIR

if [ "$(id -u)" != 0 ]; then
	echo "harden: run as root (add USER root before this step, and restore the user after it)" >&2
	exit 1
fi

modules=${HARDEN_MODULES:-}
if [ -z "$modules" ]; then
	for m in "$HARDEN_DIR"/modules/*.sh; do
		[ -e "$m" ] || continue
		modules="$modules $(basename "$m" .sh)"
	done
fi

for m in $modules; do
	if [ ! -f "$HARDEN_DIR/modules/$m.sh" ]; then
		echo "harden: no module $m" >&2
		exit 1
	fi
	echo "harden: running $m"
	sh "$HARDEN_DIR/modules/$m.sh"
done
echo "harden: done ($modules )"
