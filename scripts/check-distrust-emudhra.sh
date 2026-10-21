#!/usr/bin/env bash
# Check that every published image removes the eMudhra (emSign) roots
# (images/distrust-emudhra.sh, CVE-2026-111943).
#
# For each images/Dockerfile.* (or each Dockerfile.* in the directory given
# as $1), the final stage must have the line
#   RUN sh /usr/local/sbin/distrust-emudhra.sh
# alone (nothing chained after it), and no later instruction may undo it:
#   - a package or install step (apt-get, apt, apk, dpkg, dnf, yum, microdnf,
#     rpm, pip, pip3, npm, update-ca-certificates, curl, wget, unzip, tar, or
#     an install script such as ./aws/install), which can add or restore a
#     CA bundle;
#   - a COPY --from or ADD, which can bring a bundle from another stage or
#     image (a Python cacert.pem, an AWS CLI);
#   - a COPY into a trust store path (/etc/ssl, /etc/pki,
#     /usr/share/ca-certificates, /etc/ca-certificates, a cacerts or
#     cacert.pem file).
# Comment lines are ignored. Exits 1 and names each Dockerfile that fails.
# scripts/test-check-distrust-emudhra.sh tests it.
set -euo pipefail

dir=${1:-images}
fail=0
pkg_re='(^|[^[:alnum:]_.-])(apt-get|apt|apk|dpkg|dnf|yum|microdnf|rpm|pip|pip3|npm|update-ca-certificates|curl|wget|unzip|tar|install)([^[:alnum:]_.-]|$)'
copy_re='^[[:space:]]*(COPY[[:space:]]+(.*[[:space:]])?--from|ADD[[:space:]])|^[[:space:]]*COPY[[:space:]].*(/etc/ssl|/etc/pki|/usr/share/ca-certificates|/etc/ca-certificates|cacerts|cacert\.pem)'
run_re='^[[:space:]]*RUN[[:space:]]+sh[[:space:]]+/usr/local/sbin/distrust-emudhra\.sh[[:space:]]*$'

for f in "$dir"/Dockerfile.*; do
	# The final stage, without comment lines.
	last_from=$(grep -n '^[[:space:]]*FROM[[:space:]]' "$f" | tail -1 | cut -d: -f1)
	stage=$(tail -n +"${last_from:-1}" "$f" | grep -v '^[[:space:]]*#' || true)
	run_line=$(grep -nE "$run_re" <<<"$stage" | tail -1 | cut -d: -f1 || true)
	if [ -z "$run_line" ]; then
		echo "FAIL: $f: the final stage has no line 'RUN sh /usr/local/sbin/distrust-emudhra.sh' with nothing chained after it" >&2
		fail=1
		continue
	fi
	after=$(tail -n +"$((run_line + 1))" <<<"$stage")
	if grep -qE "$pkg_re" <<<"$after"; then
		echo "FAIL: $f: a package or install step follows distrust-emudhra.sh" >&2
		fail=1
		continue
	fi
	if grep -qE "$copy_re" <<<"$after"; then
		echo "FAIL: $f: a COPY --from, an ADD or a COPY into a trust store follows distrust-emudhra.sh" >&2
		fail=1
		continue
	fi
	echo "ok: $f"
done
exit "$fail"
