#!/usr/bin/env bash
# Compute the next PATCH version tag from the latest GitHub release.
#
# Used by the autonomous grade-A upkeep loop (the /scout-fix skill): when the
# only Scout drift is a stale base-image digest — cured by a plain rebuild, with
# no source change to PR (the #80 class) — the agent cuts the NEXT PATCH release
# so publish.yml rebuilds + republishes the images at grade A. This script is the
# ONLY sanctioned way to choose that version: it ALWAYS bumps just the patch
# component, so automation can never land a minor/major bump (those imply a
# contract change and stay human-cut — see CLAUDE.md rule 1/3).
#
# Prints e.g. `v0.1.6` to stdout. Exits non-zero (and emits nothing) if the
# latest tag isn't a clean vMAJOR.MINOR.PATCH — don't guess, escalate to a human.
set -euo pipefail

# Latest release tag: prefer the GitHub release (what publish.yml + :latest
# track); fall back to the highest semver git tag for local runs without gh.
latest=""
if command -v gh >/dev/null 2>&1 && latest=$(gh release view --json tagName -q .tagName 2>/dev/null) && [[ -n "${latest}" ]]; then
  : # got it from gh
else
  latest=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n1)
fi

if [[ -z "${latest}" ]]; then
  echo "error: could not determine the latest release tag" >&2
  exit 1
fi

# Strict vMAJOR.MINOR.PATCH only. A pre-release, build-metadata, or otherwise
# non-semver latest tag means something unusual is going on — refuse to auto-bump.
if [[ ! "${latest}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: latest tag '${latest}' is not a clean vMAJOR.MINOR.PATCH; refusing to auto-bump (escalate to a human)" >&2
  exit 2
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
echo "v${major}.${minor}.$((patch + 1))"
