#!/usr/bin/env bash
# Classify a FAILED `docker scout policy` run: is it only the VEX-blind CVE row?
#
# Docker's built-in fixable-vulnerabilities policy waives a VEX statement only
# when its product @id IS the package purl. Our OpenVEX docs (.github/vex/) use
# the standard image product + package subcomponent form, so that one row fails
# on any image with VEX-waived findings (build-godynamic), even when every
# finding is waived (#98). Per-package purl products would fix that, but purls
# carry arch-specific `?file_name=` qualifiers and change on every bump, so the
# gates use this rule instead (permanent, by decision on #98):
#
#   A failed evaluation counts as passing ONLY when
#     (1) at least one policy row failed,
#     (2) every failing row is "Fixable critical or high vulnerabilities found",
#     (3) the caller's VEX-aware probe (scripts/scout-cve-gate.sh, or the drift
#         watch's probe) found 0 unwaived fixable C/H with no probe error.
#   Anything else (another failing row, a real fixable C/H, a probe error, or a
#   table this script cannot parse) is a real failure. Fail-closed.
#
# Usage: scout-policy-verdict.sh VEX_CLEAN < policy-output
#   VEX_CLEAN  "yes" only if the VEX-aware probe ran cleanly and found nothing.
# Prints "vex-only" (exit 0) or "fail" (exit 1).
set -euo pipefail

vex_clean="${1:?usage: scout-policy-verdict.sh yes|no < policy-output}"
cve_policy='Fixable critical or high vulnerabilities found'

out="$(cat)"
# Policy table rows look like ` !      │ <policy name> │ <results>`.
failing="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*!.*│' || true)"
unexpected="$(printf '%s\n' "$failing" | grep -vF "$cve_policy" | sed '/^$/d' || true)"

if [ -n "$failing" ] && [ -z "$unexpected" ] && [ "$vex_clean" = "yes" ]; then
  echo "vex-only"
  exit 0
fi
echo "fail"
exit 1
