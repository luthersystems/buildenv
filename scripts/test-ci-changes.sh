#!/usr/bin/env bash
# Unit tests for scripts/ci-changes.sh, on a throwaway git repo.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p docs images/x scripts && echo a > README.md && echo a > images/x/Dockerfile
git add -A && git commit -qm base
base="$(git rev-parse HEAD)"

fails=0
# check <name> <want> <file...>: commits changes to the files on a branch.
check() {
  local name="$1" want="$2"; shift 2
  git checkout -q -B "t$RANDOM" "$base"
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "$RANDOM" >> "$f"; done
  git add -A && git commit -qm change
  local got
  got="$(GITHUB_OUTPUT='' bash "$here/ci-changes.sh" "$base" HEAD 2> /dev/null)"
  if [ "$got" = "full=$want" ]; then echo "ok   $name"; else echo "FAIL $name: $got, want full=$want"; fails=$((fails + 1)); fi
}
check "docs only skips" false README.md docs/a.md .claude/skills/x/SKILL.md
check "a Dockerfile runs" true README.md images/x/Dockerfile
check "a script runs" true scripts/scout-grade.sh
check "a workflow runs" true .github/workflows/build.yml
check "an action runs" true .github/actions/x/action.yml
check "VEX runs" true .github/vex/x.openvex.json
check "config runs" true common.config.mk

git checkout -q -B "t$RANDOM" "$base"
mkdir -p docs && git mv images/x/Dockerfile docs/Dockerfile.md && git commit -qm move
got="$(GITHUB_OUTPUT='' bash "$here/ci-changes.sh" "$base" HEAD 2> /dev/null)"
if [ "$got" = full=true ]; then echo "ok   a rename into docs runs"; else echo "FAIL rename: $got"; fails=$((fails + 1)); fi

got="$(GITHUB_OUTPUT='' bash "$here/ci-changes.sh" "" "" 2> /dev/null)"
if [ "$got" = full=true ]; then echo "ok   no base runs"; else echo "FAIL no base: $got"; fails=$((fails + 1)); fi
got="$(GITHUB_OUTPUT='' bash "$here/ci-changes.sh" deadbeef HEAD 2> /dev/null)"
if [ "$got" = full=true ]; then echo "ok   bad base runs"; else echo "FAIL bad base: $got"; fails=$((fails + 1)); fi

[ "$fails" = 0 ] || { echo "ci-changes: $fails test(s) failed" >&2; exit 1; }
echo "ci-changes: OK"
