# Branch protection — `main`

Governance for the protected `main` branch. The goal: the CI gates that keep the
strict grade-A images healthy are **merge-blocking**, and **automation can open
PRs but never merge them** — a human always approves.

> `main` is protected by repository rulesets in
> luthersystems/common-infrastructure (`github-org-admin/main_protection.json`
> and the org ruleset), not by classic branch protection. Change a required
> check there. This doc records why the checks are what they are.

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

- `CI (all required checks)` — the gate job `ci-all` in `build.yml`. It needs
  every job in that workflow (the image builds, the CVE scans, the non-root
  audit, the script tests and the docs-only decision), and fails when any of
  them failed, was cancelled or was skipped. `scripts/test-ci-changes.sh`,
  run by the `changes` job, fails when a job is missing from its `needs`.
- `quality / result` and `security / result` — the org's shared workflows.

One gate instead of each job by name: the build and CVE scan jobs are
matrices, one check per entry, so a list of names in the ruleset would drift
each time the matrix or `.github/scout-required-images.json` changes.

A docs-only PR (`*.md`, `docs/`, `.claude/`) still runs every job, with the
image steps skipped (`scripts/ci-changes.sh`). A merge group always runs
everything.

## Settings (kept in the ruleset)

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

> Note: a required check that never reports leaves the PR un-mergeable, which
> is the intended fail-closed behavior. The gate runs with `always()` so it
> reports on every run.
