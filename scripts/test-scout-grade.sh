#!/usr/bin/env bash
# Unit tests for scripts/scout-grade.sh and scripts/scout-cve-gate.sh. A fake
# `docker` on PATH answers `scout cves` and `buildx imagetools inspect` from
# fixture files, so the tests need no network, login or daemon.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker. Fixture files live in $FIX.
case "$1 $2" in
  "scout cves")
    echo "$*" >> "$FIX/calls"
    shift 2
    label=""
    for a in "$@"; do
      case "$a" in
        --only-cisa-kev) label=kev ;;
        critical | high) label="$a" ;;
      esac
    done
    [ -e "$FIX/cves-$label.err" ] && { echo "scan failed" >&2; exit 1; }
    [ -e "$FIX/cves-$label.txt" ] && { cat "$FIX/cves-$label.txt"; exit 2; }
    echo "No vulnerable package detected"; exit 0 ;;
  "buildx imagetools")
    ref="$4"; fmt="${6:-}"
    [ "$5" = "--raw" ] && { [ -e "$FIX/index.json" ] || exit 1; cat "$FIX/index.json"; exit 0; }
    case "$fmt" in
      *.Image*) f=image.json ;;
      *.Provenance*) f=prov.json ;;
      *.SBOM*) f=sbom.json ;;
      *.Manifest*) f="base-$(printf '%s' "$ref" | tr '/:' '__').json" ;;
    esac
    [ -e "$FIX/$f" ] || exit 1
    cat "$FIX/$f" ;;
  *) echo "fake docker: unexpected: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH" SCOUT_RETRY_SLEEP=0

# A clean two-platform image: non-root, SBOM + provenance on both, MIT only,
# built from alpine:3.24 at its current digest.
base_fixture() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/vex"
  cat > "$d/index.json" <<'EOF'
{"manifests":[
 {"digest":"sha256:a1","platform":{"os":"linux","architecture":"amd64"}},
 {"digest":"sha256:a2","platform":{"os":"unknown","architecture":"unknown"},"annotations":{"vnd.docker.reference.type":"attestation-manifest"}},
 {"digest":"sha256:b1","platform":{"os":"linux","architecture":"arm64"}},
 {"digest":"sha256:b2","platform":{"os":"unknown","architecture":"unknown"},"annotations":{"vnd.docker.reference.type":"attestation-manifest"}}]}
EOF
  echo '{"linux/amd64":{"architecture":"amd64","config":{"User":"nobody"}},"linux/arm64":{"architecture":"arm64","config":{"User":"65534:65534"}}}' > "$d/image.json"
  local mat='{"SLSA":{"materials":[{"uri":"pkg:docker/alpine@3.24?platform=linux%2Famd64","digest":{"sha256":"cafe"}}]}}'
  echo "{\"linux/amd64\":$mat,\"linux/arm64\":$mat}" > "$d/prov.json"
  local sbom='{"SPDX":{"packages":[{"name":"musl","versionInfo":"1.2","licenseConcluded":"MIT","licenseDeclared":"MIT"}]}}'
  echo "{\"linux/amd64\":$sbom,\"linux/arm64\":$sbom}" > "$d/sbom.json"
  echo '{"digest":"sha256:feed","manifests":[{"digest":"sha256:cafe"}]}' > "$d/base-alpine_3.24.json"
}

fails=0
# check <name> <want-exit> <want key=value...>: runs scout-grade.sh on $FIX.
check() {
  local name="$1" want_rc="$2"; shift 2
  local rc=0
  SCOUT_GRADE_OUT="$work/out" VEX_DIR="$FIX/vex" \
    bash "$here/scout-grade.sh" luthersystems/img:v1 img > "$work/log" 2>&1 || rc=$?
  local bad=""
  [ "$rc" = "$want_rc" ] || bad="exit $rc, want $want_rc"
  for kv in "$@"; do
    grep -qx "$kv" "$work/out" 2> /dev/null || bad="$bad; missing $kv (got: $(paste -sd' ' "$work/out" 2> /dev/null))"
  done
  if [ -n "$bad" ]; then
    echo "FAIL $name: $bad"; sed 's/^/    /' "$work/log"; fails=$((fails + 1))
  else
    echo "ok   $name"
  fi
}

export FIX="$work/fix"

base_fixture "$FIX"
check "clean image passes" 0 grade=pass critical=no high=no kev=no nonroot=no attestations=no licenses=no base=fresh

base_fixture "$FIX"
echo '{"linux/amd64":{"config":{"User":"nobody"}},"linux/arm64":{"config":{}}}' > "$FIX/image.json"
check "root on one platform fails" 1 grade=fail nonroot=yes

base_fixture "$FIX"
echo '{"linux/amd64":{"config":{"User":"0:0"}},"linux/arm64":{"config":{"User":"nobody"}}}' > "$FIX/image.json"
check "uid 0 counts as root" 1 nonroot=yes

base_fixture "$FIX"
jq '."linux/arm64" = null' "$FIX/sbom.json" > "$FIX/t" && mv "$FIX/t" "$FIX/sbom.json"
check "SBOM missing on one platform fails" 1 attestations=yes

base_fixture "$FIX"
rm "$FIX/prov.json"
check "provenance unreadable fails" 1 attestations=yes base=fresh

base_fixture "$FIX"
jq '."linux/amd64".SPDX.packages += [{"name":"ghostscript","versionInfo":"9","licenseDeclared":"AGPL-3.0-or-later OR LicenseRef-x"}]' "$FIX/sbom.json" > "$FIX/t" && mv "$FIX/t" "$FIX/sbom.json"
check "AGPL package fails" 1 licenses=yes

for lic in "AGPL-3.0+" "AGPL-1.0" "agpl-3.0-only" "AGPL" "MIT AND AGPL-1.0-or-later"; do
  base_fixture "$FIX"
  jq --arg l "$lic" '."linux/arm64".SPDX.packages += [{"name":"y","licenseConcluded":$l}]' "$FIX/sbom.json" > "$FIX/t" && mv "$FIX/t" "$FIX/sbom.json"
  check "AGPL family spelling '$lic' fails" 1 licenses=yes
done

base_fixture "$FIX"
jq '."linux/amd64".SPDX.packages += [{"name":"x","licenseDeclared":"GPL-3.0-only"}]' "$FIX/sbom.json" > "$FIX/t" && mv "$FIX/t" "$FIX/sbom.json"
check "GPL (not AGPL) passes" 0 licenses=no

base_fixture "$FIX"
echo "  ✗ HIGH CVE-2026-1111" > "$FIX/cves-high.txt"
check "unwaived fixable high fails" 1 high=yes critical=no

base_fixture "$FIX"
echo "  ✗ HIGH CVE-2026-1111" > "$FIX/cves-high.txt"
cat > "$FIX/vex/img.openvex.json" <<'EOF'
{"statements":[{"vulnerability":{"name":"CVE-2026-1111"},"status":"not_affected","products":[{"@id":"pkg:docker/luthersystems/img"}]}]}
EOF
check "VEX-waived high passes" 0 high=no grade=pass

base_fixture "$FIX"
echo "  ✗ CRITICAL (no id printed)" > "$FIX/cves-critical.txt"
check "findings without a parsed id fail closed" 1 critical=yes

base_fixture "$FIX"
touch "$FIX/cves-critical.err"
check "scan error fails closed" 1 critical=error high=error

base_fixture "$FIX"
echo "  ✗ LOW CVE-2021-44228" > "$FIX/cves-kev.txt"
check "CISA KEV finding fails" 1 kev=yes critical=no

base_fixture "$FIX"
touch "$FIX/cves-kev.err"
check "KEV scan error is recorded as error" 1 kev=error critical=no

base_fixture "$FIX"
check "scans every platform" 0 grade=pass
for p in linux/amd64 linux/arm64; do
  n="$(grep -c -- "--platform $p" "$FIX/calls" || true)"
  if [ "$n" != 3 ]; then echo "FAIL scans every platform: $p scanned $n times, want 3"; fails=$((fails + 1)); fi
done

base_fixture "$FIX"
echo '{"digest":"sha256:beef","manifests":[{"digest":"sha256:f00d"}]}' > "$FIX/base-alpine_3.24.json"
check "stale base is report only" 0 base=stale grade=pass

base_fixture "$FIX"
echo 'not json' > "$FIX/image.json"
check "an unexpected error still writes the results" 1 grade=fail critical=no nonroot=error

base_fixture "$FIX"
rm "$FIX/index.json"
check "unreadable index fails closed" 1 nonroot=error attestations=error licenses=error base=unknown

if [ "$fails" -gt 0 ]; then
  echo "scout-grade: $fails test(s) failed" >&2
  exit 1
fi
echo "scout-grade: OK"
