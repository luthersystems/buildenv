#!/usr/bin/env bash
# Check that every published image removes the eMudhra (emSign) roots
# (images/distrust-emudhra.sh, CVE-2026-111943).
#
# For each images/Dockerfile.*, the final stage must run the script, and no
# package step (apt-get, apt, apk, update-ca-certificates) may follow it,
# because a later ca-certificates install or upgrade restores the roots.
# Exits 1 and names each Dockerfile that fails.
set -euo pipefail

dir=${1:-images}
fail=0
for f in "$dir"/Dockerfile.*; do
	# Lines of the final stage only.
	last_from=$(grep -n '^FROM ' "$f" | tail -1 | cut -d: -f1)
	stage=$(tail -n +"$last_from" "$f")
	run_line=$(grep -n 'distrust-emudhra.sh' <<<"$stage" | grep 'RUN ' | tail -1 | cut -d: -f1 || true)
	if [ -z "$run_line" ]; then
		echo "FAIL: $f: the final stage does not run distrust-emudhra.sh" >&2
		fail=1
		continue
	fi
	if tail -n +"$((run_line + 1))" <<<"$stage" |
		grep -qE '(apt-get|apt|apk|update-ca-certificates)[[:space:]]'; then
		echo "FAIL: $f: a package step follows distrust-emudhra.sh" >&2
		fail=1
		continue
	fi
	echo "ok: $f"
done
exit "$fail"
