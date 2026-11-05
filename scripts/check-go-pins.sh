#!/usr/bin/env bash
# Check that every Go module security pin lives in common.config.mk.
#
# Fails when:
#   - a `go get` or `go install` in a Dockerfile names a literal version
#     (module@v1.2.3); use @v${GO_PIN_*} or a tool *_VERSION arg instead;
#   - a Dockerfile uses ${GO_PIN_X} without `ARG GO_PIN_X` earlier in the same
#     stage (the build would run `go get module@v` and fail late);
#   - a Dockerfile uses a GO_PIN_* that common.config.mk does not define;
#   - common.config.mk defines a GO_PIN_* that no Dockerfile uses.
#
# Usage: check-go-pins.sh [CONFIG [DOCKERFILE...]]
#   defaults: common.config.mk and images/Dockerfile.*
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-$ROOT/common.config.mk}"
shift || true
if [[ $# -gt 0 ]]; then FILES=("$@"); else FILES=("$ROOT"/images/Dockerfile.*); fi

fail=0
defined="$(sed -n 's/^\(GO_PIN_[A-Z0-9_]*\)=.*/\1/p' "$CONFIG" | sort -u)"

for f in "${FILES[@]}"; do
  # Join continuation lines so a `go get` split over lines is one record, and
  # keep the first line number of each record for the message.
  out="$(awk -v file="$f" -v defined="$defined" '
    BEGIN { n = split(defined, d, "\n"); for (i = 1; i <= n; i++) def[d[i]] = 1 }
    {
      if (rec == "") start = NR
      line = $0
      if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); rec = rec line " "; next }
      rec = rec line
      r = rec; rec = ""
      if (r ~ /^[[:space:]]*#/) next
      if (r ~ /^[[:space:]]*FROM[[:space:]]/) { delete argd; next }
      if (match(r, /^[[:space:]]*ARG[[:space:]]+GO_PIN_[A-Z0-9_]+/)) {
        a = substr(r, RSTART, RLENGTH); sub(/^[[:space:]]*ARG[[:space:]]+/, "", a); argd[a] = 1; next
      }
      if (r !~ /go (get|install)[[:space:]]/) next
      s = r
      while (match(s, /[^[:space:]"]+@v[0-9][^[:space:]"]*/)) {
        printf "%s:%d: literal version %s; pin it with a GO_PIN_* in common.config.mk\n", file, start, substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
      }
      s = r
      while (match(s, /\$\{GO_PIN_[A-Z0-9_]+\}/)) {
        v = substr(s, RSTART + 2, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
        if (!(v in def)) printf "%s:%d: %s is not defined in common.config.mk\n", file, start, v
        else if (!(v in argd)) printf "%s:%d: %s used without ARG %s earlier in this stage\n", file, start, v, v
      }
    }' "$f")"
  if [[ -n "$out" ]]; then echo "$out" >&2; fail=1; fi
done

for v in $defined; do
  if ! grep -q "\${$v}" "${FILES[@]}"; then
    echo "$CONFIG: $v is defined but no Dockerfile uses it" >&2; fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  echo "check-go-pins: FAIL (see common.config.mk, 'Go module security pins')" >&2
  exit 1
fi
echo "check-go-pins: OK ($(wc -w <<<"$defined" | tr -d ' ') pins, ${#FILES[@]} Dockerfiles)"
