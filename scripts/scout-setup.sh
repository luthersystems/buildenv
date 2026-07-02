#!/usr/bin/env bash
#
# Code-driven Docker Scout repo enrollment for the buildenv image set.
#
# Every incident in the July 2026 grade-gate saga traced back to hand-toggled
# Scout enablement: build-go, build-java, nginx-frontend and build-godynamic
# were each found silently un-enrolled, and an un-enrolled repo produces NO
# policy evaluation results — which the gates/watch then surface as
# "no policy results" drift. This script makes enrollment code-driven off
# .github/scout-required-images.json (required + cve_net_extra + exempt keys),
# so the enabled set can be reconciled programmatically instead of hunted
# through the Hub UI.
#
# Usage:
#   scout-setup.sh            enroll the org + enable Scout on every image in
#                             the JSON (idempotent). Alerts Slack #alert (via
#                             scripts/slack-alert.sh, if present) when it had
#                             to fix a repo that was found disabled.
#   scout-setup.sh --check    report-only: list desired vs currently-enabled;
#                             exit 1 if any desired repo is not enabled,
#                             exit 2 if enablement state cannot be determined.
#
# Env:
#   DOCKER_SCOUT_HUB_USER / DOCKER_SCOUT_HUB_PASSWORD  Docker Hub creds for the
#       scout CLI (same pair the CI gates use). Locally: export from 1Password.
#   SCOUT_ORG   defaults to luthersystems.
#
# NOTE the split of what is automatable: repo ENROLLMENT has CLI support
# (docker scout enroll / repo enable / repo list — used here). Org POLICY
# configuration (which policies gate, license lists, disable a policy) has NO
# public API or CLI — dashboard only (policy details page → Edit/Disable).
#
# Parsing fail-safe: `docker scout repo list` output is not a stable contract,
# so if its output cannot be recognized this script does NOT guess enablement
# state — in enable mode it falls back to enabling every desired repo
# (idempotent, still correct, just no "what was broken" alert); in --check
# mode it exits 2 rather than reporting a wrong answer.
set -uo pipefail

ORG="${SCOUT_ORG:-luthersystems}"
JSON=".github/scout-required-images.json"
MODE="${1:-enable}"

if [ ! -f "$JSON" ]; then
  echo "::error::${JSON} not found (run from the repo root)" >&2
  exit 1
fi

# Desired set = full grade-A set + CVE-net extras + exempt (exempt images are
# not hard-gated, but Scout coverage/analysis is still wanted on them).
desired="$(jq -r '.required[], .cve_net_extra[], (.exempt | keys[])' "$JSON" | sort -u)"
if [ -z "$desired" ]; then
  echo "::error::no images parsed from ${JSON}" >&2
  exit 1
fi

# Current enablement, best-effort. parse_ok=0 means "could not determine".
parse_ok=0
enabled=""
set +e
list_out="$(docker scout repo list --org "$ORG" 2>&1)"
list_rc=$?
set -e
if [ "$list_rc" -eq 0 ] && [ -n "$list_out" ]; then
  # Heuristic: a repo's line mentions the image name; enablement shows as
  # 'enabled'/'true'/checkmark on the same line. Guarded by the fail-safe
  # above — a parse miss can only cause extra idempotent enables, never a
  # wrong "all good".
  enabled="$(printf '%s\n' "$list_out" \
    | grep -Ei 'enabled|true|✓' \
    | grep -oE "(${ORG}/)?[a-z0-9][a-z0-9._-]*" \
    | sed "s|^${ORG}/||" | sort -u || true)"
  [ -n "$enabled" ] && parse_ok=1
fi
if [ "$parse_ok" -eq 0 ]; then
  echo "::warning::could not determine current Scout enablement from 'docker scout repo list' (rc=${list_rc}); proceeding without it"
fi

missing=""
if [ "$parse_ok" -eq 1 ]; then
  missing="$(comm -23 <(printf '%s\n' "$desired") <(printf '%s\n' "$enabled") || true)"
fi

if [ "$MODE" = "--check" ]; then
  echo "Desired Scout-enabled repos (${JSON}):"
  printf '%s\n' "$desired" | sed 's/^/  - /'
  if [ "$parse_ok" -eq 0 ]; then
    echo "::warning::enablement state undetermined — run without --check to reconcile idempotently"
    exit 2
  fi
  if [ -n "$missing" ]; then
    echo "::error::NOT Scout-enabled:"
    printf '%s\n' "$missing" | sed 's/^/  - /'
    exit 1
  fi
  echo "All desired repos are Scout-enabled."
  exit 0
fi

# Enable mode. Enroll the org (idempotent), then enable each target repo:
# only the known-missing ones when we could read state (so the Slack alert
# is precise), else all of them (idempotent fail-safe).
targets="$missing"
[ "$parse_ok" -eq 0 ] && targets="$desired"
if [ -z "$targets" ]; then
  echo "Scout enrollment OK: all $(printf '%s\n' "$desired" | wc -l | tr -d ' ') repos already enabled."
  exit 0
fi

set +e
docker scout enroll "$ORG" >/dev/null 2>&1
set -e

failed=""
fixed=""
while IFS= read -r img; do
  [ -z "$img" ] && continue
  set +e
  out="$(docker scout repo enable --org "$ORG" "${ORG}/${img}" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "enabled: ${ORG}/${img}"
    fixed="${fixed}${img}\n"
  else
    echo "::warning::failed to enable Scout on ${ORG}/${img} (rc=${rc}): ${out}"
    failed="${failed}${img}\n"
  fi
done <<< "$targets"

# Alert only on a *known* fix (state was readable and a desired repo was found
# disabled) — that is enrollment drift worth telling #alert about.
if [ "$parse_ok" -eq 1 ] && [ -n "$fixed" ] && [ -f scripts/slack-alert.sh ]; then
  pretty="$(printf "$fixed" | sed '/^$/d' | paste -sd', ' -)"
  bash scripts/slack-alert.sh "⚠️ *Scout enrollment drift* — repo(s) were disabled in Docker Scout and have been re-enabled automatically: ${pretty}. (Un-enrolled repos produce no policy results and silently fall out of the grade gates.)"
fi

if [ -n "$failed" ]; then
  echo "::error::some repos could not be enabled (see warnings above)"
  exit 1
fi
echo "Scout enrollment reconciled."
