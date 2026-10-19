#!/usr/bin/env bash
#
# Grade a PUBLISHED image against the Docker Scout grade-A rules, in CI, with
# no org-level Scout call.
#
# Why: `docker scout policy` (the old grade) and Scout repo enrollment are
# org-level Scout API calls. CI logs in to Docker Hub with OIDC only, and an
# OIDC token (like an organization access token) has no Scout scope, so every
# such call returns 403. Since the OIDC switch (#134) the gates could not read
# a grade, and the drift issue (#150) could never close. Image-level Scout
# commands (`docker scout cves`) and registry reads work with OIDC, so this
# script rebuilds the grade from them. The grade on Docker Hub itself is
# unaffected; this is only how CI decides.
#
# Rules (Docker's built-in health-score policies -> how they are checked here):
#   fixable critical/high  scripts/scout-cve-gate.sh            gate
#   high-profile CVEs      scripts/scout-cve-gate.sh --kev      gate (CISA KEV
#                          list; Docker's own policy adds a short curated list)
#   non-root default user  image config .User, every platform   gate
#   attestations           SBOM + provenance, every platform    gate
#   AGPL licenses          the SBOM attestation; the license
#                          list is .github/scout-policy/policy-config.json
#                                                               gate
#   outdated base images   provenance materials vs the tag's
#                          current digest                       report only
# The base-image rule is report-only because provenance lists every image the
# build pulled (builder stages too), not only the final base, so it would
# over-report. The daily scout-autofix already ships base refreshes.
#
# Usage: scout-grade.sh <image-ref> <image-key>
#   <image-ref>  a pushed tag, e.g. luthersystems/build-go:v0.1.40
#   <image-key>  e.g. build-go (VEX scope; see scout-cve-gate.sh)
#
# SCOUT_GRADE_OUT=<file>  if set, gets one key=value line per rule:
#   critical, high, kev, nonroot, attestations, licenses (yes|no = violation,
#   or error), base (fresh|stale|unknown), grade (pass|fail).
#
# Exit 0 = grade A, 1 = a gated rule failed or could not be checked
# (fail closed). Needs `docker login` (pull), docker buildx and the Scout CLI.
set -euo pipefail

ref="${1:?usage: scout-grade.sh <image-ref> <image-key>}"
key="${2:?usage: scout-grade.sh <image-ref> <image-key>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy_config="${SCOUT_LICENSE_CONFIG:-$here/../.github/scout-policy/policy-config.json}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

declare -A result=()
fail=0
# record <rule> <value>: yes and error fail the grade.
record() {
  result[$1]="$2"
  case "$2" in yes | error) fail=1 ;; esac
}

inspect() { docker buildx imagetools inspect "$@"; }

echo "== Grade ${ref}"

# 1) Fixable critical/high and 2) CISA KEV, both VEX-aware and fail-closed.
if SCOUT_CVE_OUT="$tmp/cve.out" bash "$here/scout-cve-gate.sh" "registry://${ref}" "$key"; then
  record critical no; record high no
elif [ -s "$tmp/cve.out" ]; then
  record critical "$(sed -n 's/^critical=//p' "$tmp/cve.out")"
  record high "$(sed -n 's/^high=//p' "$tmp/cve.out")"
  # A format-drift failure can leave both at "no"; never let that pass.
  [ "${result[critical]}${result[high]}" != nono ] || { record critical error; record high error; }
else
  record critical error; record high error
fi
# scout-cve-gate.sh exits 1 for findings and for scan errors alike; both fail
# the grade, which is what matters here.
if bash "$here/scout-cve-gate.sh" --kev "registry://${ref}" "$key"; then
  record kev no
else
  record kev yes
fi

# The rest reads the published index and its attestations.
if ! inspect "$ref" --raw > "$tmp/index.json" 2> "$tmp/err"; then
  echo "::error::cannot read the index of ${ref}: $(head -c 300 "$tmp/err")"
  record nonroot error; record attestations error; record licenses error
  result[base]=unknown
else
  platforms="$(jq '[.manifests[]?
      | select((.annotations["vnd.docker.reference.type"] // "") != "attestation-manifest")
      | select((.platform.os // "") != "unknown")] | length' "$tmp/index.json")"
  # buildx prints a platform-keyed map for an index and a bare value for a
  # single-platform image. norm turns both into a list of values.
  norm='if type == "object" and (has("SLSA") or has("SPDX") or has("config") or has("architecture")) then [.] elif type == "object" then [.[]] else [] end'

  # 3) Non-root default user on every platform.
  if inspect "$ref" --format '{{json .Image}}' > "$tmp/image.json" 2> "$tmp/err"; then
    users="$(jq -r "$norm | .[] | (.config.User // \"\")" "$tmp/image.json")"
    n_users="$(printf '%s\n' "$users" | sed '/^$/d' | wc -l)"
    root_users="$(printf '%s\n' "$users" | grep -cE '^$|^(root|0)(:.*)?$' || true)"
    if [ "$(jq "$norm | length" "$tmp/image.json")" -lt 1 ]; then
      echo "::error::no image config read for ${ref}"; record nonroot error
    elif [ "$root_users" -gt 0 ] || [ "$n_users" -lt "$(jq "$norm | length" "$tmp/image.json")" ]; then
      echo "::error::${ref} runs as root on at least one platform (USER: $(printf '%s' "$users" | paste -sd, -))"
      record nonroot yes
    else
      echo "non-root: OK ($(printf '%s' "$users" | sort -u | paste -sd, -))"; record nonroot no
    fi
  else
    echo "::error::cannot read the image config of ${ref}: $(head -c 300 "$tmp/err")"; record nonroot error
  fi

  # 4) SBOM + provenance on every platform.
  inspect "$ref" --format '{{json .Provenance}}' > "$tmp/prov.json" 2> "$tmp/err.prov" || echo null > "$tmp/prov.json"
  inspect "$ref" --format '{{json .SBOM}}' > "$tmp/sbom.json" 2> "$tmp/err.sbom" || echo null > "$tmp/sbom.json"
  n_prov="$(jq "$norm | map(select(.SLSA != null)) | length" "$tmp/prov.json")"
  n_sbom="$(jq "$norm | map(select(.SPDX != null)) | length" "$tmp/sbom.json")"
  if [ "$platforms" -ge 1 ] && [ "$n_prov" -eq "$platforms" ] && [ "$n_sbom" -eq "$platforms" ]; then
    echo "attestations: OK (SBOM + provenance on ${platforms} platform(s))"; record attestations no
  else
    echo "::error::${ref} attestations missing: platforms=${platforms} provenance=${n_prov} sbom=${n_sbom}"
    record attestations yes
  fi

  # 5) No license from the AGPL list in any SBOM package.
  if [ "$n_sbom" -lt 1 ]; then
    echo "::error::no SBOM to check licenses on for ${ref}"; record licenses error
  elif ! jq -e '.policies[] | select(.name == "copyleft-license") | .config.licenses | length > 0' "$policy_config" > /dev/null; then
    echo "::error::no copyleft license list in ${policy_config}"; record licenses error
  else
    hits="$(jq -r --slurpfile cfg "$policy_config" "
        (\$cfg[0].policies[] | select(.name == \"copyleft-license\") | .config.licenses | map(ascii_upcase)) as \$bad
        | $norm | .[] | .SPDX.packages[]?
        | . as \$p
        | [(.licenseConcluded // \"\"), (.licenseDeclared // \"\")]
        | map(ascii_upcase | [scan(\"[A-Z0-9.+-]+\")]) | add
        | select(any(.[]; . as \$l | \$bad | index(\$l)))
        | \"\(\$p.name)@\(\$p.versionInfo // \"?\")\"" "$tmp/sbom.json" | sort -u)"
    if [ -n "$hits" ]; then
      echo "::error::${ref} has packages under a disallowed (AGPL) license:"
      printf '%s\n' "$hits" | sed 's/^/  - /'
      record licenses yes
    else
      echo "licenses: OK (no AGPL package)"; record licenses no
    fi
  fi

  # 6) Base images (report only): a material whose tag now has another digest.
#    Provenance v0.2 lists them as .materials, v1 as .resolvedDependencies.
  result[base]=fresh
  jq -r "$norm | .[] | (.SLSA.materials[]?, .SLSA.buildDefinition.resolvedDependencies[]?)
      | select((.uri // \"\") | startswith(\"pkg:docker/\"))
      | [.uri, (.digest.sha256 // \"\")] | @tsv" "$tmp/prov.json" | sort -u > "$tmp/materials.tsv"
  stale=""
  while IFS=$'\t' read -r uri digest; do
    name="${uri#pkg:docker/}"; name="${name%%\?*}"
    tag="${name##*@}"; name="${name%@*}"
    case "$tag" in sha256:* | "") continue ;; esac
    [ -n "$digest" ] || continue
    if ! inspect "${name}:${tag}" --format '{{json .Manifest}}' > "$tmp/base.json" 2> /dev/null; then
      result[base]=unknown; continue
    fi
    current="$(jq -r '(.digest, .manifests[]?.digest) // empty | sub("^sha256:"; "")' "$tmp/base.json")"
    if ! printf '%s\n' "$current" | grep -qx "$digest"; then
      stale="${stale}${name}:${tag} "
    fi
  done < "$tmp/materials.tsv"
  if [ -n "$stale" ]; then
    result[base]=stale
    echo "::notice::${ref} was built from image(s) that now have a newer digest: ${stale}(report only; a rebuild picks them up)"
  else
    echo "base images: ${result[base]}"
  fi
fi

grade=pass; [ "$fail" = 0 ] || grade=fail
if [ -n "${SCOUT_GRADE_OUT:-}" ]; then
  : > "$SCOUT_GRADE_OUT"
  for k in critical high kev nonroot attestations licenses base; do
    echo "${k}=${result[$k]:-error}" >> "$SCOUT_GRADE_OUT"
  done
  echo "grade=${grade}" >> "$SCOUT_GRADE_OUT"
fi
echo "== ${ref}: grade ${grade}"
[ "$grade" = pass ]
