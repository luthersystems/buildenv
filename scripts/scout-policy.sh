#!/usr/bin/env bash
# Evaluate the buildenv Docker Scout policy set against an image (#98).
#
# Since scout-cli moved `docker scout policy` to LOCAL Rego evaluation, it runs
# Docker's BUILT-IN default policy set unless it is given a config. It does not
# read the policies configured in the Scout org dashboard. That is the whole of
# #98: the built-in "No copyleft licenses" policy (GPL/LGPL/MPL/…, where the org
# set is AGPL-only) and a built-in fixable-CVE policy whose VEX match ignores
# the standard image+subcomponent OpenVEX form our waivers use.
#
# The org's policy set now lives in the repo, under .github/scout-policy/:
#   policy-config.json               copyleft = AGPL-3 only (as the dashboard);
#                                    built-in fixable-vulnerabilities off,
#                                    fixable-vulnerabilities-vex on
#   fixable-vulnerabilities-vex.rego built-in copy + standard OpenVEX matching
# Every other built-in policy runs unchanged.
#
# Usage: scout-policy.sh IMAGE_REF [extra docker scout policy flags]
# Exit code: docker scout policy --exit-code (0 pass, 2 policies not met).
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 IMAGE_REF [flags]" >&2
  exit 64
fi

POLICY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/scout-policy"
ref="$1"
shift

exec docker scout policy "$ref" \
  --org luthersystems \
  --exit-code \
  --policy-config "$POLICY_DIR/policy-config.json" \
  --policy-file "$POLICY_DIR/fixable-vulnerabilities-vex.rego" \
  "$@"
