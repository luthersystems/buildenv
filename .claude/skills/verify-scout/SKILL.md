---
name: verify-scout
description: "Confirm the grade-A build images are still clean BEFORE opening a PR — the local mirror of the CI Scout gates. Use after touching any image, common.config.mk, or a Dockerfile, and as the self-check step at the end of /scout-fix. Examples: 'verify the scout gate locally', 'is build-go-alpine still grade A', 'check before PR'."
---

# Verify the grade-A bill of health locally

Run this before opening any PR that touches `images/`, `common.config.mk`, or a
Dockerfile. It reproduces the two PR-time gates (`build.yml` → `cve-scan`) so you
catch a regression locally instead of in CI. The required set is read from
`.github/scout-required-images.json`.

## Run it

```bash
cd images
sha=$(git rev-parse HEAD)
fail=0
for img in $(jq -r '.required[]' ../.github/scout-required-images.json); do
  echo "═══ $img ═══"
  make PLATFORMS=linux/amd64 DOCKER_BUILDX_OPTS=--load GIT_REVISION="$sha" "$img"
  ref="local://luthersystems/${img}:${sha}"

  # Gate 1 — fixable CRITICAL/HIGH CVEs (must be ZERO)
  docker scout cves "$ref" --only-fixed --only-severities critical,high --exit-code \
    || { echo "❌ $img: fixable CRITICAL/HIGH CVE(s)"; fail=1; }

  # Gate 2 — default non-root user (must be non-empty and not root/0)
  user=$(docker image inspect "luthersystems/${img}:${sha}" --format '{{.Config.User}}')
  case "$user" in
    ""|root|0|0:0|root:root) echo "❌ $img: default USER='$user' is root"; fail=1 ;;
    *) echo "✅ $img: USER='$user'" ;;
  esac

  docker scout quickview "$ref"   # eyeball the full C/H/M/L + policy picture
done
[ "$fail" -eq 0 ] && echo "✅ all required images clean" || { echo "❌ regressions above"; exit 1; }
```

## What "OK" looks like

- **Gate 1:** `docker scout cves … --only-fixed --only-severities critical,high`
  exits 0 with no rows for every required image.
- **Gate 2:** every required image reports a non-root `USER` (`build`, uid `1000`,
  or `nobody` for service-base-alpine).
- `quickview` shows no *fixable* HIGH/CRITICAL and ideally `0C 0H` overall.

## What this CANNOT verify locally (by design)

- **Supply-chain attestations** and the **true A–F grade** only exist on the
  *pushed* image — a `--load` build carries no attestations. Those are enforced
  at release by `publish.yml` → `scout-policy` (`docker scout policy --exit-code`)
  and `verify-attestations`. Don't try to attest a `--load` build.
- **Unfixable** CVEs won't fail Gate 1 (it's `--only-fixed`); they're tracked
  non-blocking in CI. Drop the `--only-fixed` flag if you want to see the total.

If anything is red, go back to **`/scout-fix`** and pick the matching fix pattern.
