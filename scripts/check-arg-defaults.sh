#!/usr/bin/env bash
# Check that every Dockerfile ARG default matches common.config.mk.
#
# The Makefile passes the central value of each version with --build-arg, so a
# stale `ARG X=<old>` default never shows in CI: only a bare `docker build`
# gets the old version. build-e2e kept `ARG GOLANG_VERSION=1.26.4` across
# several Go bumps that way (#198, #199).
#
# Fails when a Dockerfile has `ARG X=<v>` and common.config.mk sets X to a
# different value. An ARG that common.config.mk does not define is not checked.
#
# Usage: check-arg-defaults.sh [CONFIG [DOCKERFILE...]]
#   defaults: common.config.mk and images/Dockerfile.*
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-$ROOT/common.config.mk}"
shift || true
if [[ $# -gt 0 ]]; then FILES=("$@"); else FILES=("$ROOT"/images/Dockerfile.*); fi

[[ -s "$CONFIG" ]] || { echo "check-arg-defaults: $CONFIG is missing or empty" >&2; exit 1; }

fail=0
n=0
for f in "${FILES[@]}"; do
  out="$(awk -v file="$f" '
    function unq(v) { gsub(/^["\047]|["\047]$/, "", v); return v }
    FNR == NR {
      if (match($0, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[?:]?=/)) {
        k = $0; sub(/[[:space:]]*[?:]?=.*/, "", k)
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        conf[k] = unq(v)
      }
      next
    }
    {
      # Join continuation lines so `ARG A=1 \` + `B=2` is one record.
      if (rec == "") start = FNR
      line = $0
      if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); rec = rec line " "; next }
      r = rec line; rec = ""
      if (r ~ /^[[:space:]]*#/) next
      if (toupper(r) !~ /^[[:space:]]*ARG[[:space:]]/) next
      sub(/^[[:space:]]*[Aa][Rr][Gg][[:space:]]+/, "", r)
      # Each word is NAME or NAME=VALUE; VALUE may be quoted.
      while (match(r, /^[A-Za-z_][A-Za-z0-9_]*(=("[^"]*"|\047[^\047]*\047|[^[:space:]]*))?/)) {
        w = substr(r, 1, RLENGTH); r = substr(r, RLENGTH + 1); sub(/^[[:space:]]+/, "", r)
        if (index(w, "=") == 0) continue
        k = substr(w, 1, index(w, "=") - 1); v = unq(substr(w, index(w, "=") + 1))
        if (!(k in conf)) continue
        printf "CHECKED\n"
        if (conf[k] != v) printf "%s:%d: ARG %s=%s, but common.config.mk sets %s=%s\n", file, start, k, v, k, conf[k]
      }
    }' "$CONFIG" "$f")"
  n=$((n + $(grep -c '^CHECKED$' <<<"$out" || true)))
  bad="$(grep -v '^CHECKED$' <<<"$out" || true)"
  if [[ -n "$bad" ]]; then echo "$bad" >&2; fail=1; fi
done

if [[ $fail -ne 0 ]]; then
  echo "check-arg-defaults: FAIL (bump the ARG default to the common.config.mk value)" >&2
  exit 1
fi
# A parse that silently matches nothing must not pass.
if [[ $n -eq 0 ]]; then
  echo "check-arg-defaults: FAIL (no ARG default matched a common.config.mk variable)" >&2
  exit 1
fi
echo "check-arg-defaults: OK ($n ARG defaults, ${#FILES[@]} Dockerfiles)"
