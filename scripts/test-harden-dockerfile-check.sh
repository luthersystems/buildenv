#!/usr/bin/env bash
# shellcheck disable=SC1003,SC2016 # the fixture lines are literal Dockerfile text
# Self-test for images/harden/check/dockerfile.sh: each fixture Dockerfile
# must pass, fail or be skipped as expected. Run by `make test-check-harden`
# and by CI (build.yml `script-tests`).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check="$here/../images/harden/check/dockerfile.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bad=0

# expect <pass|fail> <name> <final-stage lines...>
expect() {
	local want=$1 name=$2
	shift 2
	local d="$tmp/$name"
	mkdir -p "$d"
	{
		echo 'FROM golang:1 AS build'
		echo 'RUN --mount=type=bind,source=harden,target=/harden sh /harden/harden.sh'
		if [ "${base:-}" != none ]; then echo "FROM ${base:-alpine:3}"; fi
		printf '%s\n' "$@"
	} >"$d/Dockerfile.x"
	local got=pass out
	out=$(bash "$check" "$d" 2>&1) || got=fail
	if [ "$got" = pass ] && grep -q '^skip:' <<<"$out"; then got=skip; fi
	if [ "$got" = "$want" ]; then
		echo "ok: $name ($want)"
	else
		echo "FAIL: $name: want $want, got $got" >&2
		bad=1
	fi
}

run='RUN --mount=type=bind,source=harden,target=/harden sh /harden/harden.sh'
expect pass basic 'RUN apk add --no-cache ca-certificates' "$run" 'USER nobody'
expect pass later-check "$run" 'RUN set -eux; go version'
expect pass comment-word "$run" '# adapt this later'
expect pass word-in-arg "$run" 'RUN echo adapter apkg'
expect fail missing 'RUN apk add --no-cache ca-certificates' 'USER nobody'
expect fail only-in-build-stage 'USER nobody'
expect fail commented-out "# $run" 'USER nobody'
expect fail apk-after "$run" 'RUN apk add --no-cache curl'
expect fail apt-after "$run" 'RUN apt-get update && apt-get install -y curl'
expect fail update-ca-eol "$run" 'RUN update-ca-certificates'
expect fail dpkg-after "$run" 'RUN dpkg -i /tmp/ca-certificates.deb'
expect fail continued-line "$run" 'RUN set -eux; \' '    apk upgrade'
expect fail copy-bundle "$run" 'COPY --from=x /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/'
expect fail copy-cacerts "$run" 'COPY cacerts /opt/java/openjdk/lib/security/cacerts'

expect fail chained-apk "$run && apk add --no-cache ca-certificates-bundle"
expect fail continued-run "$run \\" '    && apk upgrade'
expect fail only-named 'RUN rm -f /harden/harden.sh'
expect fail echo-named 'RUN echo skip sh /harden/harden.sh'
expect fail no-mount 'RUN sh /harden/harden.sh'
expect fail other-target 'RUN --mount=type=bind,source=harden,target=/kit sh /harden/harden.sh'
expect fail update-ca-trust "$run" 'RUN update-ca-trust extract'
expect pass from-stage 'RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh'
expect pass continued-mount 'RUN --mount=type=bind,from=harden,source=/harden,target=/harden \' '    sh /harden/harden.sh' 'USER nobody'
base=scratch expect skip scratch-final 'COPY --from=build /etc/ssl /etc/ssl'
base='--platform=$BUILDPLATFORM gcr.io/distroless/static' expect skip distroless-final 'COPY --from=build /etc/ssl /etc/ssl'
base='--platform=$BUILDPLATFORM alpine:3' expect fail platform-missing 'USER nobody'
expect fail copy-from-az "$run" 'COPY --from=azcli /az /az'
expect fail copy-from-aws "$run" 'COPY --from=aws /usr/local/aws-cli/ /usr/local/aws-cli/'
expect fail aws-install "$run" 'RUN unzip awscliv2.zip && ./aws/install'
expect fail add-url "$run" 'ADD https://example.com/bundle.tar.gz /opt/'
expect fail copy-cacert-pem "$run" 'COPY cacert.pem /usr/lib/python3/site-packages/certifi/cacert.pem'
expect fail npm-after "$run" 'RUN npm install -g newman'
expect pass copy-config "$run" 'COPY nginx/nginx.conf /etc/nginx/nginx.conf'

exit "$bad"
