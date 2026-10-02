#!/usr/bin/env bash
# Unit-test the buildenv Docker Scout policies in .github/scout-policy/ (#98)
# with OPA. Downloads a pinned, sha256-verified OPA (OPA_VERSION and sums in
# common.config.mk) unless `opa` is already on PATH. Scout's custom builtins
# (oci.referrer, scout.parse_purl) are declared from scout-builtins.json so the
# tests can mock them with `with`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_DIR="$REPO_ROOT/.github/scout-policy"
read_cfg() { sed -n "s/^$1=//p" "$REPO_ROOT/common.config.mk" | head -1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

opa="$(command -v opa || true)"
if [[ -z "$opa" ]]; then
  ver="$(read_cfg OPA_VERSION)"
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 want="$(read_cfg OPA_SHA256_LINUX_AMD64)" ;;
    aarch64 | arm64) arch=arm64 want="$(read_cfg OPA_SHA256_LINUX_ARM64)" ;;
    *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  bin="opa_linux_${arch}_static"
  curl -fsSL --retry 3 --retry-all-errors -o "$tmp/opa" \
    "https://github.com/open-policy-agent/opa/releases/download/v${ver}/${bin}"
  got="$(sha256sum "$tmp/opa" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then
    echo "error: checksum mismatch for $bin: want $want, got $got" >&2
    exit 1
  fi
  chmod +x "$tmp/opa"
  opa="$tmp/opa"
fi

# OPA's own capabilities + Scout's custom builtins.
"$opa" capabilities --current >"$tmp/base.json"
jq -s '.[0] * {builtins: (.[0].builtins + .[1].builtins)}' \
  "$tmp/base.json" "$POLICY_DIR/scout-builtins.json" >"$tmp/caps.json"

"$opa" test --capabilities "$tmp/caps.json" -v \
  "$POLICY_DIR/fixable-vulnerabilities-vex.rego" \
  "$POLICY_DIR/fixable-vulnerabilities-vex_test.rego"

# The config must keep the org's AGPL-only license set and swap the VEX-blind
# built-in for our policy. Catch an accidental edit that re-opens #98.
cfg="$POLICY_DIR/policy-config.json"
jq -e '
  ([.policies[] | select(.name == "copyleft-license") | .config.licenses[]]
     | length > 0 and all(test("^AGPL-")))
  and ([.policies[] | select(.name == "fixable-vulnerabilities") | .enabled] == [false])
  and ([.policies[] | select(.name == "fixable-vulnerabilities-vex") | .enabled] == [true])
' "$cfg" >/dev/null || { echo "error: $cfg lost the #98 settings" >&2; exit 1; }
echo "policy-config.json: OK"
