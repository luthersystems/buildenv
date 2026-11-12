#!/usr/bin/env bash
# Self-test for scripts/check-arg-defaults.sh, with fixture Dockerfiles.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-arg-defaults.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'GOLANG_VERSION=1.27.4\nALPINE_VERSION=3.24 # trailing comment\nNODE_VERSION ?= 24.1.0\nMAVEN_VERSION:="3.10"\n' >"$T/config.mk"
pass=0; failn=0

# expect NAME WANT(0|1) PATTERN — PATTERN must appear in the output when WANT=1.
expect() {
  local name="$1" want="$2" pat="$3" rc=0 out
  local cfg="${CFG:-$T/config.mk}"
  # NAME may list several fixtures, space separated.
  # shellcheck disable=SC2086
  out="$(cd "$T" && bash "$CHECK" "$cfg" $name 2>&1)" || rc=$?
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

cat >"$T/indented" <<'D'
  ARG ALPINE_VERSION=3.23
D
expect indented 1 "ARG ALPINE_VERSION=3.23"

cat >"$T/assignments" <<'D'
ARG NODE_VERSION=24.1.0 MAVEN_VERSION=3.10
D
expect assignments 0 ""

cat >"$T/second" <<'D'
ARG ALPINE_VERSION=3.24 GOLANG_VERSION=1.26.4
D
expect second 1 "second:1: ARG GOLANG_VERSION=1.26.4"

cat >"$T/lower" <<'D'
arg GOLANG_VERSION=1.26.4
D
expect lower 1 "ARG GOLANG_VERSION=1.26.4"

cat >"$T/continued" <<'D'
# ARG GOLANG_VERSION=1.0 in a comment is fine
ARG ALPINE_VERSION=3.24 \
    GOLANG_VERSION="1.26.4"
D
expect continued 1 "continued:2: ARG GOLANG_VERSION=1.26.4"

expect "ok stale" 1 "stale:2:"

cat >"$T/none" <<'D'
ARG OTHER_VERSION=1
D
expect none 1 "no ARG default matched"

: >"$T/empty.mk"
CFG="$T/empty.mk" expect ok 1 "missing or empty"

echo "test-check-arg-defaults: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
