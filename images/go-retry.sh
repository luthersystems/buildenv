#!/bin/sh
#
# Retry a Go module-fetching command through transient proxy.golang.org errors.
#
# Why this exists: the v0.1.16 publish failed three times in a row (2026-08-20,
# run 32405801237 attempts 1-3), each time in a DIFFERENT image -- build-api,
# build-go, then build-js -- and every time with the same shape:
#
#   go: <module>: read "https://proxy.golang.org/.../@v/<ver>.zip":
#       stream error: stream ID NNN; INTERNAL_ERROR; received from peer
#
# That is an HTTP/2 stream reset from the module proxy, not a defect in the
# build. Go does NOT retry this class on its own -- one reset fails the whole
# `go get`, which fails the RUN, which fails the image, which (with fail-fast)
# cancels the entire publish matrix.
#
# It matters here because the publish surface is wide: ~20 `go get` sites across
# 7 Dockerfiles, each built for 2 architectures, so ~40 independent module-fetch
# operations per publish. At even a low per-operation failure rate, at least one
# failing per publish is likely rather than exceptional. Wrapping each site turns
# a proxy hiccup into a few seconds of delay instead of a failed release.
#
# Deliberately narrow: this retries the WHOLE command, so it must only wrap
# commands that are safe to re-run from scratch (`go get`, `go build`,
# `go mod download` -- all idempotent). Do not wrap anything with side effects
# outside the module cache.
#
# Usage: go-retry go get example.com/mod@v1.2.3 other.com/mod@v4.5.6
set -eu

attempts="${GO_RETRY_ATTEMPTS:-5}"
delay="${GO_RETRY_DELAY:-3}"

n=1
while true; do
  if "$@"; then
    [ "$n" -gt 1 ] && echo "go-retry: succeeded on attempt $n/$attempts" >&2
    exit 0
  fi
  if [ "$n" -ge "$attempts" ]; then
    echo "go-retry: FAILED after $n attempt(s): $*" >&2
    exit 1
  fi
  echo "go-retry: attempt $n/$attempts failed, retrying in ${delay}s: $*" >&2
  sleep "$delay"
  n=$((n + 1))
  delay=$((delay * 2))
done
