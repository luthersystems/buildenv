#!/usr/bin/env bash
# Test the build-harden kit on real base images: each fixture in
# scripts/testdata/harden is built with the kit bind-mounted the way a
# consumer repo mounts it (a named build context, as `FROM build-harden AS
# harden` gives), then checked with images/harden/check/image.sh.
#
#   build ok, check ok:  debian-mixed, alpine-appended, temurin, debian-jdk
#                        (blocked.certs is a link), al2023
#   build ok, check ok:  aaa-removed (a bundle with AAA Certificate Services)
#   build fails:         aaa-chain (a listed intermediate still chains to a
#                        trusted root), malformed (a listed root in a PEM
#                        block with no END line)
#   build ok, check ok:  node (NODE_OPTIONS=--use-openssl-ca)
#   check fails:         undone (a later step adds a root back),
#                        unhardened (no kit), node-unset (Node reads its
#                        built-in roots)
#
# Needs docker with buildx, network access to pull the base images, and on
# the host openssl, keytool and certutil (image.sh's tools). Run by
# `make test-harden` and by CI (build.yml `harden-tests`). Pass fixture names
# to run only those.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kit=$here/../images/harden
fx=$here/testdata/harden
bad=0

build() {
	local k=$kit
	# aaa-chain needs a list without AAA Certificate Services, so that a
	# listed intermediate still has a trusted root to chain to.
	if [ "$1" = aaa-chain ]; then
		k=$work/kit-without-aaa
		rm -rf "$k" && cp -r "$kit" "$k"
		sed -i '/ comodo-aaa-certificate-services.pem /d' "$k/policy/ca-distrust.list"
	fi
	docker buildx build --load --progress plain \
		--build-context harden="$k" \
		--build-context certs="$kit/policy/ca-distrust" \
		-f "$fx/Dockerfile.$1" -t "harden-test-$1" "$fx" >"$work/$1.log" 2>&1
}

# expect NAME BUILD CHECK: BUILD and CHECK are ok or fail (CHECK is - when
# the build must fail). On a failed build, MATCH (optional) must be in its log.
expect() {
	local name=$1 want_build=$2 want_check=$3 match=${4:-} got_build=ok got_check=-
	build "$name" || got_build=fail
	if [ "$got_build" = fail ] && [ -n "$match" ] && ! grep -qF "$match" "$work/$name.log"; then
		got_build="fail (without '$match')"
	fi
	if [ "$got_build" = ok ]; then
		got_check=ok
		bash "$kit/check/image.sh" "harden-test-$name" >"$work/$name.check" 2>&1 || got_check=fail
	fi
	if [ "$got_build" = "$want_build" ] && [ "$got_check" = "$want_check" ]; then
		echo "ok: $name (build $got_build, check $got_check)"
	else
		echo "FAIL: $name: want build $want_build, check $want_check; got build $got_build, check $got_check" >&2
		tail -30 "$work/$name.log" >&2
		[ ! -f "$work/$name.check" ] || tail -30 "$work/$name.check" >&2
		bad=1
	fi
	docker image rm -f "harden-test-$name" >/dev/null 2>&1 || true
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

only=" $* "
run() { if [ "$only" = "  " ] || [[ $only == *" $1 "* ]]; then expect "$@"; fi; }

run debian-mixed ok ok
run alpine-appended ok ok
run temurin ok ok
run debian-jdk ok ok
run al2023 ok ok
run aaa-chain fail - 'still verifies against /usr/local/lib/oldcertifi/cacert.pem'
run aaa-removed ok ok
run malformed fail - 'in a layout this module cannot edit'
run undone ok fail
run node ok ok
run node-unset ok fail
run unhardened ok fail

exit "$bad"
