# Branch protection — `main`

Governance for the protected `main` branch. The goal: the CI gates that keep the
strict grade-A images healthy are **merge-blocking**, and **automation can open
PRs but never merge them** — a human always approves.

> These settings are applied in repo **Settings → Branches** (or via the API
> command below). They are not expressible as a committed file, so this doc is
> the source of truth / runbook; keep it in sync when the required checks change.

## Why this matters for automation

The upkeep loop (weekly `scout-drift` → a scheduled Claude agent → PR) is designed
to **propose** fixes, not ship them. The lock that enforces "propose, don't merge":

- **Require a pull request + at least one approving review.** A GitHub App / bot
  cannot supply an approving review, so its PR can't reach the required count on
  its own — a human must approve.
- **The automation runs as a dedicated GitHub App, never a human PAT or an admin**,
  and is **not** added to any bypass / "allow specified actors" list. Apps are
  subject to branch protection unless explicitly allowed to bypass — so don't.
- Auto-merge (if enabled) is still safe: it only fires **after** required reviews
  and checks are satisfied, so it can't skip the human approval.

## Required status checks

Strict (security/grade-A — **must** be required):

- `Resolve Docker Scout image lists`
- `Non-root user audit (all images)` — hard-fails only on a strict-image root regression
- `CVE scan (build-api)`
- `CVE scan (build-go-alpine)`
- `CVE scan (service-base-alpine)`

Build integrity for the strict images (**recommended** — don't merge a broken build):

- `build-api - amd64 docker build`, `build-api - arm64 docker build`
- `build-go-alpine - amd64 docker build`, `build-go-alpine - arm64 docker build`
- `service-base-alpine - amd64 docker build`, `service-base-alpine - arm64 docker build`

Optional (broader net): `CVE scan (build-go)` and the remaining
`<image> - <arch> docker build` checks for the non-strict images.

> The strict set tracks `.github/scout-required-images.json`. If you promote a
> 4th image to strict there, add its `CVE scan (...)` and build checks here too.

## Settings

- **Require a pull request before merging** → Require approvals: **1**;
  **Dismiss stale approvals when new commits are pushed** (so a bot can't push
  after a human approves and then merge).
- **Require status checks to pass** → add the checks above; **Require branches to
  be up to date before merging**.
- **Require conversation resolution before merging**.
- **Do not allow bypassing the above settings** (enforce on admins too) — strongest
  "automation/no-one merges around the gate" guarantee. Trade-off: human admins
  can't hotfix-merge either; relax only if you need that.
- **Do not** add the automation App (or anyone) to "Allow specified actors to
  bypass required pull requests."
- Block force pushes and branch deletion (defaults for a protected branch).
- Optional: add a `.github/CODEOWNERS` and enable **Require review from Code
  Owners** to pin who must approve image changes.

## Apply via API (one shot)

An admin can apply the strict + recommended set with `gh`:

```bash
cat > /tmp/buildenv-main-protection.json <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Resolve Docker Scout image lists",
      "Non-root user audit (all images)",
      "CVE scan (build-api)",
      "CVE scan (build-go-alpine)",
      "CVE scan (service-base-alpine)",
      "build-api - amd64 docker build",
      "build-api - arm64 docker build",
      "build-go-alpine - amd64 docker build",
      "build-go-alpine - arm64 docker build",
      "service-base-alpine - amd64 docker build",
      "service-base-alpine - arm64 docker build"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON

gh api -X PUT repos/luthersystems/buildenv/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  --input /tmp/buildenv-main-protection.json
```

Verify:

```bash
gh api repos/luthersystems/buildenv/branches/main/protection \
  --jq '{checks: .required_status_checks.contexts, reviews: .required_pull_request_reviews.required_approving_review_count, admins: .enforce_admins.enabled}'
```

> Note: a required check that never reports (e.g. its job was skipped because an
> upstream job failed) leaves the PR un-mergeable — which is the intended
> fail-closed behavior.
