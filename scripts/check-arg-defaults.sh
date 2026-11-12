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

fail=0
n=0
for f in "${FILES[@]}"; do
  out="$(awk -v file="$f" '
    FNR == NR {
      if (match($0, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[?:]?=/)) {
        k = $0; sub(/[[:space:]]*[?:]?=.*/, "", k)
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        conf[k] = v
      }
      next
    }
    match($0, /^[[:space:]]*ARG[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=/) {
      k = $0; sub(/^[[:space:]]*ARG[[:space:]]+/, "", k); sub(/=.*/, "", k)
      v = $0; sub(/^[^=]*=/, "", v); sub(/[[:space:]].*$/, "", v); gsub(/^["\047]|["\047]$/, "", v)
      if (k in conf) {
        printf "CHECKED\n"
        if (conf[k] != v) printf "%s:%d: ARG %s=%s, but common.config.mk sets %s=%s\n", file, FNR, k, v, k, conf[k]
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
echo "check-arg-defaults: OK ($n ARG defaults, ${#FILES[@]} Dockerfiles)"
