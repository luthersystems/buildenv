#!/usr/bin/env bash
# Evaluate the buildenv Docker Scout policy set against an image (#98).
#
# scout-cli runs `docker scout policy` as LOCAL Rego evaluation of Docker's
# built-in policy set. It does NOT read the policies configured in the Scout
# org dashboard. Unconfigured, the built-in "No copyleft licenses" policy flags
# GPL/LGPL/MPL/EPL/CDDL, where the org set flags AGPL only: the phantom
# copyleft row of #98. .github/scout-policy/policy-config.json sets the org's
# AGPL-only list; every other built-in policy runs unchanged.
#
# Do NOT add --policy-file / --policy-dir here. Either one REPLACES the whole
# built-in set (only the given files load; #135 shipped that way and the gates
# evaluated 1 policy instead of 7), and in that mode the CLI does not fetch the
# image's VEX attestation at all.
#
# Known gap (#98): the built-in fixable-vulnerabilities policy waives a VEX
# statement only when its product @id IS the package purl; our OpenVEX docs
# use the standard image product + package subcomponent form, so that row
# still fails on build-godynamic. scout-drift.yml's VEX-aware probe covers it.
#
# Usage: scout-policy.sh IMAGE_REF [extra docker scout policy flags]
# Exit code: docker scout policy --exit-code (0 pass, 2 policies not met).
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 IMAGE_REF [flags]" >&2
  exit 64
fi

CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/scout-policy/policy-config.json"
ref="$1"
shift

exec docker scout policy "$ref" \
  --org luthersystems \
  --exit-code \
  --policy-config "$CONFIG" \
  "$@"
