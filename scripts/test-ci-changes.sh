#!/usr/bin/env bash
# Unit tests for scripts/ci-changes.sh, on a throwaway git repo, and a check
# that build.yml's gate job (ci-all) needs every other job.
#
# Why: ci-changes.sh decides whether the image builds and CVE scans run. A bug
# that prints full=false for a code change would skip them while the required
# gate stays green, so build.yml's changes job runs this test before it
# decides. A job missing from the gate's needs list could fail without
# blocking the merge.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="$here/../.github/workflows/build.yml"
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
check "LICENSE runs" true LICENSE
check ".gitignore runs" true .gitignore

git checkout -q -B "t$RANDOM" "$base"
mkdir -p docs && git mv images/x/Dockerfile docs/Dockerfile.md && git commit -qm move
got="$(GITHUB_OUTPUT='' bash "$here/ci-changes.sh" "$base" HEAD 2> /dev/null)"
if [ "$got" = full=true ]; then echo "ok   a rename into docs runs"; else echo "FAIL rename: $got"; fails=$((fails + 1)); fi

got="$(GITHUB_OUTPUT='' bash "$here/ci-changes.sh" "" "" 2> /dev/null)"
if [ "$got" = full=true ]; then echo "ok   no base runs"; else echo "FAIL no base: $got"; fails=$((fails + 1)); fi
got="$(GITHUB_OUTPUT='' bash "$here/ci-changes.sh" deadbeef HEAD 2> /dev/null)"
if [ "$got" = full=true ]; then echo "ok   bad base runs"; else echo "FAIL bad base: $got"; fails=$((fails + 1)); fi
got="$(GITHUB_OUTPUT='' bash "$here/ci-changes.sh" 2> /dev/null)"
if [ "$got" = full=true ]; then echo "ok   no arguments runs"; else echo "FAIL no arguments: $got"; fails=$((fails + 1)); fi

# Every job in build.yml, except the gate itself, must be in its needs.
jobs="$(awk '/^jobs:/{in_jobs=1; next} in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/{sub(/^  /,""); sub(/:.*/,""); print}' "$workflow" | grep -vx ci-all | sort)"
needs="$(awk '/^  ci-all:/{in_gate=1} in_gate && /^    needs:/{print; exit}' "$workflow" |
  sed -e 's/^ *needs: *\[//' -e 's/\].*//' | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort)"
if [ -n "$jobs" ] && [ "$jobs" = "$needs" ]; then
  echo "ok   gate needs every job"
else
  echo "FAIL gate needs list differs from build.yml's jobs"
  diff <(echo "$jobs") <(echo "$needs")
  fails=$((fails + 1))
fi

[ "$fails" = 0 ] || { echo "ci-changes: $fails test(s) failed" >&2; exit 1; }
echo "ci-changes: OK"
