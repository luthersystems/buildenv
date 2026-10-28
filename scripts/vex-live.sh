#!/usr/bin/env bash
#
# Print an OpenVEX doc with only its live waivers: statements whose TTL in
# .github/vex-ttl.json is unexpired (scripts/vex-ttl.jq). publish.yml attaches
# this output, not the raw doc, so Docker Hub's grade stops honoring a waiver
# when the CI gate does.
#
# Usage: vex-live.sh <openvex.json> <image-key>
# VEX_TTL, SCOUT_TODAY, VEX_TTL_MAX_DAYS as in scripts/scout-cve-gate.sh.
set -euo pipefail
doc="${1:?usage: vex-live.sh <openvex.json> <image-key>}"
key="${2:?usage: vex-live.sh <openvex.json> <image-key>}"
ttl="${VEX_TTL:-.github/vex-ttl.json}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$ttl" ] || { echo "vex-live: no TTL file $ttl" >&2; exit 1; }
jq -L "$here" --slurpfile t "$ttl" --arg key "$key" \
  --arg today "${SCOUT_TODAY:-$(date -u +%F)}" --argjson max "${VEX_TTL_MAX_DAYS:-120}" '
  include "vex-ttl";
  .statements |= map(select(.status != "not_affected"
    or (ttl_state($t[0]; $key; .vulnerability.name; $today; $max; 0).state
        | . == "ok" or . == "soon")))
' "$doc"
