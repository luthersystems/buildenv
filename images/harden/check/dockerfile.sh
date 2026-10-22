#!/usr/bin/env bash
# Check that each Dockerfile runs the build-harden kit last.
#
# Why: harden.sh only holds if nothing after it can undo it. A later package
# step can restore a CA bundle, and a COPY --from can bring one from another
# stage or image, so the kit must run after them. This check reads the
# Dockerfile; check/image.sh proves the result on the built image.
#
# For each Dockerfile given (a file, or every Dockerfile* in a directory;
# default: the current directory), the final stage must have a RUN whose
# whole command is `sh /harden/harden.sh` (HARDEN_* settings may come
# first) with the pinned kit bind-mounted at /harden:
#   FROM luthersystems/build-harden:<version>@sha256:<digest> AS harden
#   ...
#   RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
# --allow-local-kit (first argument) also accepts source=harden with no
# from=, a kit in the build context: only buildenv, which builds the kit,
# uses it.
# (a line continued with a backslash counts as one line), with nothing chained
# after it, and no later instruction may undo it:
#   - a package or install step (apt-get, apt, apk, dpkg, dnf, yum, microdnf,
#     rpm, pip, pip3, npm, update-ca-certificates, update-ca-trust, curl,
#     wget, unzip, tar, or an install script such as ./aws/install);
#   - a COPY --from or ADD, which can bring a bundle from another stage or
#     image (a Python cacert.pem, an AWS CLI);
#   - a COPY into a trust store path (/etc/ssl, /etc/pki,
#     /usr/share/ca-certificates, /etc/ca-certificates, a cacerts or
#     cacert.pem file).
# A final stage with no shell (FROM scratch or a distroless image) cannot run
# the kit; it is reported and skipped, and check/image.sh must cover it (copy
# its trust store from a stage that ran the kit).
# Comment lines are ignored. Exits 1 and names each Dockerfile that fails.
set -euo pipefail

pkg_re='(^|[^[:alnum:]_.-])(apt-get|apt|apk|dpkg|dnf|yum|microdnf|rpm|pip|pip3|npm|update-ca-certificates|update-ca-trust|curl|wget|unzip|tar|install)([^[:alnum:]_.-]|$)'
copy_re='^[[:space:]]*(COPY[[:space:]]+(.*[[:space:]])?--from|ADD[[:space:]])|^[[:space:]]*COPY[[:space:]].*(/etc/ssl|/etc/pki|/usr/share/ca-certificates|/etc/ca-certificates|cacerts|cacert\.pem)'
run_re='^[[:space:]]*RUN[[:space:]]+--mount=type=bind,([^[:space:]]*,)?target=/harden(,[^[:space:]]*)?[[:space:]]+(HARDEN_[A-Z_]+=[^[:space:]]+[[:space:]]+)*sh[[:space:]]+/harden/harden\.sh[[:space:]]*$'
# The kit stage: FROM luthersystems/build-harden:<tag>@sha256:<digest> AS <name>.
kit_re='^[[:space:]]*FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?luthersystems/build-harden:[^[:space:]@]+@sha256:[0-9a-f]{64}[[:space:]]+AS[[:space:]]+'

local_kit=0
if [ "${1:-}" = --allow-local-kit ]; then
	local_kit=1
	shift
fi

files=()
for arg in "${@:-.}"; do
	if [ -d "$arg" ]; then
		for f in "$arg"/Dockerfile*; do
			case $f in *.dockerignore | *.md) continue ;; esac
			[ -f "$f" ] && files+=("$f")
		done
	else
		files+=("$arg")
	fi
done
[ "${#files[@]}" -gt 0 ] || { echo "dockerfile.sh: no Dockerfile found" >&2; exit 1; }

fail=0
for f in "${files[@]}"; do
	# Drop comment lines, then join continued lines.
	text=$(grep -v '^[[:space:]]*#' "$f" | awk '{ if (sub(/\\[[:space:]]*$/, "")) { buf = buf $0 " "; next } print buf $0; buf = "" } END { if (buf != "") print buf }')
	last_from=$(grep -n '^[[:space:]]*FROM[[:space:]]' <<<"$text" | tail -1 | cut -d: -f1)
	stage=$(tail -n +"${last_from:-1}" <<<"$text")
	base=$(head -1 <<<"$stage" | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; exit } }')
	case $base in
	scratch | *distroless*)
		echo "skip: $f: the final stage ($base) has no shell; check/image.sh must cover it"
		continue
		;;
	esac
	run_line=$(grep -nE "$run_re" <<<"$stage" | tail -1 | cut -d: -f1 || true)
	if [ -z "$run_line" ]; then
		echo "FAIL: $f: the final stage has no 'RUN --mount=type=bind,...,target=/harden sh /harden/harden.sh' with nothing chained after it" >&2
		fail=1
		continue
	fi
	# The mount must be the pinned kit: from=<a stage that is
	# luthersystems/build-harden pinned by digest>,source=/harden. buildenv
	# itself mounts its own kit from the build context (--allow-local-kit).
	opts=$(sed -n "${run_line}p" <<<"$stage" | sed -E 's/^[[:space:]]*RUN[[:space:]]+--mount=([^[:space:]]+).*/\1/')
	from=$(tr , '\n' <<<"$opts" | sed -n 's/^from=//p')
	src=$(tr , '\n' <<<"$opts" | sed -n 's/^source=//p')
	if [ -n "$from" ]; then
		if ! grep -qiE "${kit_re}${from}[[:space:]]*\$" <<<"$text" || [ "$src" != /harden ]; then
			echo "FAIL: $f: mount the pinned kit: 'FROM luthersystems/build-harden:<version>@sha256:<digest> AS $from' and 'from=$from,source=/harden'" >&2
			fail=1
			continue
		fi
	elif [ "$local_kit" = 0 ] || [ "$src" != harden ]; then
		echo "FAIL: $f: the kit is not mounted from a pinned luthersystems/build-harden stage (from=<stage>,source=/harden)" >&2
		fail=1
		continue
	fi
	after=$(tail -n +"$((run_line + 1))" <<<"$stage")
	if grep -qE "$pkg_re" <<<"$after"; then
		echo "FAIL: $f: a package or install step follows harden.sh" >&2
		fail=1
		continue
	fi
	if grep -qE "$copy_re" <<<"$after"; then
		echo "FAIL: $f: a COPY --from, an ADD or a COPY into a trust store follows harden.sh" >&2
		fail=1
		continue
	fi
	echo "ok: $f"
done
exit "$fail"
