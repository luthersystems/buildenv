#!/usr/bin/env bash
#
# Decide whether a PR needs the full image CI (image builds + CVE scans).
#
# A PR that changes only documentation does not: no image, script, workflow
# or Action harness changed. Anything else runs the full CI, and so does any
# error here (fail closed). The heavy jobs still run, so their required check
# names report, but they skip their steps (build.yml, `changes` job).
#
# Usage: ci-changes.sh <base-sha> <head-sha>
#   Prints full=true|false; appends it to $GITHUB_OUTPUT when that is set.
set -uo pipefail

base="${1:-}"; head="${2:-}"
out() {
  echo "full=$1"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "full=$1" >> "$GITHUB_OUTPUT"
  exit 0
}

[ -n "$base" ] && [ -n "$head" ] || { echo "ci-changes: no base/head; running full CI" >&2; out true; }
if ! files="$(git diff --no-renames --name-only "${base}...${head}" 2>&1)"; then
  echo "ci-changes: git diff failed; running full CI: $files" >&2; out true
fi
[ -n "$files" ] || { echo "ci-changes: no changed files; running full CI" >&2; out true; }

# --no-renames: a rename lists its old path too, so moving a script into
# docs/ is not docs-only.
# Docs-only paths. Never list a path a build, gate or workflow reads.
docs_only() {
  case "$1" in
    *.md | docs/* | .claude/* | LICENSE | .gitignore) return 0 ;;
    *) return 1 ;;
  esac
}
while IFS= read -r f; do
  if ! docs_only "$f"; then
    echo "ci-changes: $f is not docs-only; running full CI" >&2; out true
  fi
done <<< "$files"
echo "ci-changes: docs-only change; skipping image builds and CVE scans" >&2
out false
