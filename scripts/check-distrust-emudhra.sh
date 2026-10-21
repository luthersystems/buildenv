#!/usr/bin/env bash
# Check that every published image removes the eMudhra (emSign) roots
# (images/distrust-emudhra.sh, CVE-2026-111943).
#
# For each images/Dockerfile.* (or each Dockerfile.* in the directory given
# as $1), the final stage must RUN the script, and no later instruction may
# undo it:
#   - a package step (apt-get, apt, apk, dpkg, dnf, yum, microdnf, rpm, pip,
#     update-ca-certificates), which can install or restore ca-certificates;
#   - a COPY or ADD into a trust store path (/etc/ssl, /etc/pki,
#     /usr/share/ca-certificates, /etc/ca-certificates, a cacerts file).
# Comment lines are ignored. Exits 1 and names each Dockerfile that fails.
# scripts/test-check-distrust-emudhra.sh tests it.
set -euo pipefail

dir=${1:-images}
fail=0
pkg_re='(^|[^[:alnum:]_.-])(apt-get|apt|apk|dpkg|dnf|yum|microdnf|rpm|pip|pip3|update-ca-certificates)([^[:alnum:]_.-]|$)'
copy_re='^[[:space:]]*(COPY|ADD)[[:space:]].*(/etc/ssl|/etc/pki|/usr/share/ca-certificates|/etc/ca-certificates|cacerts)'

for f in "$dir"/Dockerfile.*; do
	# The final stage, without comment lines.
	last_from=$(grep -n '^[[:space:]]*FROM[[:space:]]' "$f" | tail -1 | cut -d: -f1)
	stage=$(tail -n +"${last_from:-1}" "$f" | grep -v '^[[:space:]]*#' || true)
	run_line=$(grep -nE '^[[:space:]]*RUN[[:space:]].*distrust-emudhra\.sh' <<<"$stage" | tail -1 | cut -d: -f1 || true)
	if [ -z "$run_line" ]; then
		echo "FAIL: $f: the final stage does not run distrust-emudhra.sh" >&2
		fail=1
		continue
	fi
	after=$(tail -n +"$((run_line + 1))" <<<"$stage")
	if grep -qE "$pkg_re" <<<"$after"; then
		echo "FAIL: $f: a package step follows distrust-emudhra.sh" >&2
		fail=1
		continue
	fi
	if grep -qE "$copy_re" <<<"$after"; then
		echo "FAIL: $f: a COPY or ADD into a trust store follows distrust-emudhra.sh" >&2
		fail=1
		continue
	fi
	echo "ok: $f"
done
exit "$fail"
