#!/usr/bin/env bash
# Guard the buildenv Docker Scout policy config (#98).
#
# scripts/scout-policy.sh must run Docker's FULL built-in set with only
# .github/scout-policy/policy-config.json applied. Fail if the config loses the
# org's AGPL-only copyleft list, or if anyone adds --policy-file/--policy-dir
# (either REPLACES the built-in set and stops the CLI fetching VEX).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cfg="$REPO_ROOT/.github/scout-policy/policy-config.json"

jq -e '
  [.policies[] | select(.name == "copyleft-license") | .config.licenses[]]
  | length > 0 and all(test("^AGPL-"))
' "$cfg" >/dev/null || { echo "error: $cfg lost the AGPL-only copyleft list (#98)" >&2; exit 1; }

jq -e '[.policies[] | select(.enabled == false)] | length == 0' "$cfg" >/dev/null \
  || { echo "error: $cfg disables a built-in policy; that weakens the gate" >&2; exit 1; }

if grep -nE -- '--policy-(file|dir|bundle)' "$REPO_ROOT/scripts/scout-policy.sh" | grep -v '^[0-9]*:#'; then
  echo "error: scripts/scout-policy.sh replaces the built-in policy set (see its header)" >&2
  exit 1
fi
echo "scout policy config: OK"
