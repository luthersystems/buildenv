#!/usr/bin/env bash
# Self-test for scripts/check-go-pins.sh, with fixture Dockerfiles.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-go-pins.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'GO_PIN_X_NET=0.62.0\n' >"$T/config.mk"
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
FROM golang AS b
ARG TOOL_VERSION
ARG GO_PIN_X_NET
RUN go get "example.com/tool@v${TOOL_VERSION}" \
      golang.org/x/net@v${GO_PIN_X_NET}
# go get golang.org/x/net@v0.1.0 in a comment is fine
D
expect ok 0 ""

cat >"$T/literal" <<'D'
FROM golang
ARG GO_PIN_X_NET
RUN go get example.com/tool \
      golang.org/x/net@v0.60.0
D
expect literal 1 "literal version golang.org/x/net@v0.60.0"

cat >"$T/undefined" <<'D'
FROM golang
ARG GO_PIN_X_SYS
RUN go get golang.org/x/sys@v${GO_PIN_X_SYS} golang.org/x/net@v${GO_PIN_X_NET}
D
expect undefined 1 "GO_PIN_X_SYS is not defined"

cat >"$T/otherstage" <<'D'
FROM golang AS a
ARG GO_PIN_X_NET
FROM golang AS b
RUN go get golang.org/x/net@v${GO_PIN_X_NET}
D
expect otherstage 1 "used without ARG GO_PIN_X_NET"

cat >"$T/unused" <<'D'
FROM golang
RUN go version
D
expect unused 1 "GO_PIN_X_NET is defined but no Dockerfile uses it"

echo "test-check-go-pins: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
