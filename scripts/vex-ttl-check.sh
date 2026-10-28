#!/usr/bin/env bash
#
# Check .github/vex-ttl.json against the OpenVEX docs under .github/vex/:
#   - every not_affected statement has a TTL entry, and every entry a statement
#     (a stale entry would silently re-arm a waiver that is added back later);
#   - each date is a real YYYY-MM-DD at most VEX_TTL_MAX_DAYS (120) days out.
#     A past date is not an error here (it would fail every PR at once); the
#     gate stops applying that waiver, so only the affected image goes red;
#   - each entry names an issue as "#N" or "owner/repo#N".
# Runs in CI (make vex-ttl-check, build.yml script-tests). Exit 1 on any problem.
set -euo pipefail
vex_dir="${VEX_DIR:-.github/vex}"
ttl="${VEX_TTL:-.github/vex-ttl.json}"
today="${SCOUT_TODAY:-$(date -u +%F)}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob
docs=("$vex_dir"/*.json)
[ -f "$ttl" ] || { echo "vex-ttl-check: no TTL file $ttl" >&2; exit 1; }
stmts="$(jq -r '.statements[]? | select(.status == "not_affected")
  | .vulnerability.name as $id | .products[]?."@id"
  | capture("/(?<img>[^/@]+)(@|$)").img + "\t" + $id' "${docs[@]}" /dev/null | sort -u)"
problems="$(jq -r -L "$here" --arg today "$today" --argjson max "${VEX_TTL_MAX_DAYS:-120}" \
  --arg stmts "$stmts" '
  include "vex-ttl";
  . as $t
  | ($stmts | split("\n") | map(select(. != "") | split("\t"))) as $s
  | ($s[] | select($t[.[0]][.[1]] == null) | "no TTL entry for \(.[0]) \(.[1])"),
    (to_entries[] | select(.key | startswith("_") | not) | .key as $img
     | .value | to_entries[] | .key as $id | .value as $v
     | (if ($s | map(. == [$img, $id]) | any) then empty
        else "TTL entry \($img) \($id) has no not_affected statement" end),
       (ttl_state($t; $img; $id; $today; $max; 0).state as $st
        | if $st == "invalid" then "\($img) \($id): invalid expires \($v.expires | tojson)" else empty end),
       (if ($v.issue | type == "string" and test("^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+$")) then empty
        else "\($img) \($id): issue must be #N or owner/repo#N, got \($v.issue | tojson)" end))
' "$ttl")"
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed 's/^/vex-ttl-check: /' >&2
  exit 1
fi
echo "vex-ttl-check: OK"
