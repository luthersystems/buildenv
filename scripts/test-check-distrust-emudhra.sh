#!/usr/bin/env bash
# Self-test for scripts/check-distrust-emudhra.sh: each fixture Dockerfile
# must pass or fail as expected. Run by `make test-check-distrust-emudhra`
# and by CI (build.yml `script-tests`).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check="$here/check-distrust-emudhra.sh"
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
		echo 'RUN sh /usr/local/sbin/distrust-emudhra.sh'
		echo 'FROM alpine:3'
		printf '%s\n' "$@"
	} >"$d/Dockerfile.x"
	local got=pass
	bash "$check" "$d" >/dev/null 2>&1 || got=fail
	if [ "$got" = "$want" ]; then
		echo "ok: $name ($want)"
	else
		echo "FAIL: $name: want $want, got $got" >&2
		bad=1
	fi
}

run='RUN sh /usr/local/sbin/distrust-emudhra.sh'
expect pass basic 'RUN apk add --no-cache ca-certificates' "$run" 'USER nobody'
expect pass later-check "$run" 'RUN set -eux; go version'
expect pass comment-word "$run" '# adapt this later'
expect pass word-in-arg "$run" 'RUN echo adapter apkg'
expect fail missing 'RUN apk add --no-cache ca-certificates' 'USER nobody'
expect fail only-in-build-stage 'USER nobody'
expect fail commented-out '# RUN sh /usr/local/sbin/distrust-emudhra.sh' 'USER nobody'
expect fail apk-after "$run" 'RUN apk add --no-cache curl'
expect fail apt-after "$run" 'RUN apt-get update && apt-get install -y curl'
expect fail update-ca-eol "$run" 'RUN update-ca-certificates'
expect fail dpkg-after "$run" 'RUN dpkg -i /tmp/ca-certificates.deb'
expect fail continued-line "$run" 'RUN set -eux; \' '    apk upgrade'
expect fail copy-bundle "$run" 'COPY --from=x /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/'
expect fail copy-cacerts "$run" 'COPY cacerts /opt/java/openjdk/lib/security/cacerts'

expect fail chained-apk 'RUN sh /usr/local/sbin/distrust-emudhra.sh && apk add --no-cache ca-certificates-bundle'
expect fail continued-run 'RUN sh /usr/local/sbin/distrust-emudhra.sh \' '    && apk upgrade'
expect fail only-named 'RUN rm -f /usr/local/sbin/distrust-emudhra.sh'
expect fail echo-named 'RUN echo skip distrust-emudhra.sh'
expect fail copy-from-az "$run" 'COPY --from=azcli /az /az'
expect fail copy-from-aws "$run" 'COPY --from=aws /usr/local/aws-cli/ /usr/local/aws-cli/'
expect fail aws-install "$run" 'RUN unzip awscliv2.zip && ./aws/install'
expect fail add-url "$run" 'ADD https://example.com/bundle.tar.gz /opt/'
expect fail copy-cacert-pem "$run" 'COPY cacert.pem /usr/lib/python3/site-packages/certifi/cacert.pem'
expect fail npm-after "$run" 'RUN npm install -g newman'
expect pass copy-config "$run" 'COPY nginx/nginx.conf /etc/nginx/nginx.conf'

exit "$bad"
