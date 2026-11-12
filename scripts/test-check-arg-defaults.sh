#!/usr/bin/env bash
# Self-test for scripts/check-arg-defaults.sh, with fixture Dockerfiles.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-arg-defaults.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'GOLANG_VERSION=1.27.4\nALPINE_VERSION=3.24 # trailing comment\n' >"$T/config.mk"
pass=0; failn=0

# expect NAME WANT(0|1) PATTERN — PATTERN must appear in the output when WANT=1.
expect() {
  local name="$1" want="$2" pat="$3" rc=0 out
  out="$(bash "$CHECK" "$T/config.mk" "$T/$name" 2>&1)" || rc=$?
  if [[ "$want" == 0 && $rc -eq 0 ]] || [[ "$want" == 1 && $rc -ne 0 && "$out" == *"$pat"* ]]; then
    pass=$((pass + 1))
  else
    echo "FAIL $name (rc=$rc): $out"; failn=$((failn + 1))
  fi
}

cat >"$T/ok" <<'D'
ARG GOLANG_VERSION=1.27.4
ARG ALPINE_VERSION="3.24"
ARG OTHER_VERSION=9.9.9
FROM golang:${GOLANG_VERSION}
ARG GOLANG_VERSION
D
expect ok 0 ""

cat >"$T/stale" <<'D'
FROM ubuntu:22.04
ARG GOLANG_VERSION=1.26.4
D
expect stale 1 "stale:2: ARG GOLANG_VERSION=1.26.4, but common.config.mk sets GOLANG_VERSION=1.27.4"

cat >"$T/stalecomment" <<'D'
  ARG ALPINE_VERSION=3.23
D
expect stalecomment 1 "ARG ALPINE_VERSION=3.23"

echo "test-check-arg-defaults: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
