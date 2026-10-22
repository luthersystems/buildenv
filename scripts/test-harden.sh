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
# The positive control (policy/ca-keep.list): a root the policy keeps must
# stay trusted.
#
#   build fails:         keep-blocked (the distrust list also lists a kept
#                        root), keep-lost (a kept chain does not verify after
#                        the module)
#   check fails:         keep-removed (a later step removes a kept root from
#                        the system bundle), keep-java-removed (from the JDK
#                        keystore), keep-nss-distrusted (an NSS database
#                        distrusts it)
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
	# keep-blocked: the distrust list also lists a kept root.
	if [ "$1" = keep-blocked ]; then
		k=$work/kit-blocks-kept
		rm -rf "$k" && cp -r "$kit" "$k"
		cp "$k/policy/ca-keep/usertrust-rsa-certification-authority.pem" "$k/policy/ca-distrust/"
		grep ' usertrust-rsa-certification-authority.pem ' "$k/policy/ca-keep.list" >>"$k/policy/ca-distrust.list"
	fi
	# keep-lost: the keep list also keeps an intermediate whose root is in
	# no bundle, made here, so the kept chain cannot verify.
	if [ "$1" = keep-lost ]; then
		k=$work/kit-keeps-lost
		rm -rf "$k" && cp -r "$kit" "$k"
		openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=lost-root -days 30 \
			-keyout "$work/lost-root.key" -out "$work/lost-root.pem" 2>/dev/null
		openssl req -newkey rsa:2048 -nodes -subj /CN=lost-intermediate \
			-keyout "$work/lost-int.key" -out "$work/lost-int.csr" 2>/dev/null
		printf 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$work/lost-int.ext"
		openssl x509 -req -in "$work/lost-int.csr" -CA "$work/lost-root.pem" -CAkey "$work/lost-root.key" \
			-CAcreateserial -days 30 -extfile "$work/lost-int.ext" -out "$k/policy/ca-keep/lost-intermediate.pem" 2>/dev/null
		echo "$(openssl x509 -in "$k/policy/ca-keep/lost-intermediate.pem" -outform der | sha256sum | cut -c1-64) intermediate lost-intermediate.pem test lost intermediate" >>"$k/policy/ca-keep.list"
	fi
	docker buildx build --load --progress plain \
		--build-context harden="$k" \
		--build-context certs="$kit/policy/ca-distrust" \
		--build-context keep="$kit/policy/ca-keep" \
		-f "$fx/Dockerfile.$1" -t "harden-test-$1" "$fx" >"$work/$1.log" 2>&1
}

# expect NAME BUILD CHECK: BUILD and CHECK are ok or fail (CHECK is - when
# the build must fail). MATCH (optional) must be in the log of the step that
# fails: the build's, or the check's.
expect() {
	local name=$1 want_build=$2 want_check=$3 match=${4:-} got_build=ok got_check=-
	build "$name" || got_build=fail
	if [ "$got_build" = fail ] && [ -n "$match" ] && ! grep -qF "$match" "$work/$name.log"; then
		got_build="fail (without '$match')"
	fi
	if [ "$got_build" = ok ]; then
		got_check=ok
		bash "$kit/check/image.sh" "harden-test-$name" >"$work/$name.check" 2>&1 || got_check=fail
		if [ "$got_check" = fail ] && [ -n "$match" ] && ! grep -qF "$match" "$work/$name.check"; then
			got_check="fail (without '$match')"
		fi
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
run keep-blocked fail - 'usertrust-rsa-certification-authority.pem is in both'
run keep-lost fail - 'lost-intermediate.pem (kept) no longer verifies against /etc/ssl/certs/ca-certificates.crt'
run keep-removed ok fail 'kept sectigo-rsa-dv-secure-server-ca.pem does not verify against it'
run keep-java-removed ok fail 'does not hold kept root usertrust-rsa-certification-authority.pem'
run keep-nss-distrusted ok fail 'distrusts kept usertrust-rsa-certification-authority.pem'

exit "$bad"
