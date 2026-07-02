# CLAUDE.md

Guidance for coding agents working in **buildenv** — the common build and run
containers for Luther applications. Shared with Codex via the `AGENTS.md`
symlink. Global agent rules come from your client.

**Also read:** [README.md](README.md) → "Image security policies" for the
grade-A model and the two-tier CI gate.

## What this repo is

A set of multi-arch Docker images (in `images/`) published to Docker Hub under
`luthersystems/<image>`. Downstream repos pin a release via `BUILDENV_TAG` and
consume these as `docker run` tools or as `FROM` bases in multi-stage builds.

| Image | Role |
|---|---|
| `build-api`, `build-go`, `build-go-alpine`, `build-godynamic` | Go build/test/lint toolchains |
| `build-js`, `build-java`, `build-e2e`, `build-swaggercodegen` | JS / Java / e2e / codegen toolchains |
| `nginx-frontend` | Static frontend serving base |
| `service-base-alpine` | Minimal **prod runtime** base (runs as `nobody`) |

## Build & test

```bash
# Build locally (single arch, loaded into the local daemon)
cd images && make PLATFORMS=$(../scripts/local_platform.sh) DOCKER_BUILDX_OPTS=--load <image>

# Build one image for an explicit platform
cd images && make PLATFORMS=linux/amd64 DOCKER_BUILDX_OPTS=--load build-go-alpine
```

There is no unit-test suite; correctness is "the image builds multi-arch and
passes the Docker Scout gate." Releases happen on `v*` tag push (publish.yml) —
created via the GitHub release UI.

## Versions are centralized — change them in ONE place

**All tool/base versions live in [`common.config.mk`](common.config.mk)** (Go,
Alpine, golangci-lint, buf, go-swagger, git-lfs, aws/az CLI, node, …). The
Dockerfiles take them as `ARG`s; the Makefile passes the central value at build.
Dockerfile `ARG <X>=<default>` lines are fallbacks only — when you bump a
version, bump `common.config.mk`, and update the matching `ARG` default if it
drifts (CI builds use the central value regardless).

## Docker Scout grade-A bill of health

Seven images **must** stay at Docker Scout grade A: `build-api`, `build-go`,
`build-go-alpine`, `build-godynamic`, `build-java`, `nginx-frontend`,
`service-base-alpine`. The other three (`build-e2e`, `build-js`,
`build-swaggercodegen`) are **exempt** — each fails only on third-party-bundled,
upstream-frozen CVEs whose vulnerable code is actually in the image's execute
path (azure-cli's vendored crypto, the swagger-codegen JAR's libs, build-e2e's
bundled binaries), so there's no buildenv-side fix and a VEX `not_affected` would
be false; tracked in
[`docs/upstream-cve-backlog.md`](docs/upstream-cve-backlog.md), re-promoted once
the bundled artifact goes clean. `build-godynamic` stays grade-A via an OpenVEX
`not_affected` waiver ([`.github/vex/`](.github/vex/)) for one upstream-frozen
moby finding (CVE-2026-34040 — a daemon AuthZ bug not reachable from the compose
client it ships): the PR gate ([`scripts/scout-cve-gate.sh`](scripts/scout-cve-gate.sh))
lists fixable C/H findings and drops VEX-waived ones, fail-closed (Scout's own
`cves --exit-code` can't honor VEX — only `docker scout policy` does). The
required + exempt sets are the single source of truth in
[`.github/scout-required-images.json`](.github/scout-required-images.json), gated
in CI three ways:

| When | Workflow | Gate |
|---|---|---|
| every PR | `build.yml` → `cve-scan` + `non-root-audit` | fixable CRITICAL/HIGH CVEs (required set); non-root audit across **all** images — hard-fails only if a required image regresses to root, reports the rest |
| release (tag) | `publish.yml` → `scout-policy` | `docker scout policy --exit-code` (true grade) + attestations. **Hard for human-cut releases; report-only for automation's interim patch releases** (`release-meta` detects `claude[bot]`) |
| daily cron | `scout-drift.yml` | re-scan published `:latest`; open/refresh a `scout-drift` issue on drift, auto-close on recovery, and **escalate the remediation SLA** |

**Remediation SLA (customer — [`.github/scout-sla.json`](.github/scout-sla.json)):**
fixable **Critical → published fix within 15 days**, fixable **High → 30 days**;
unfixable CVEs are exempt ("where fixes are available") but kept on the latest
patches. The daily drift watch labels the issue (`sla:critical`/`sla:high`) and
escalates (`sla:at-risk`/`sla:breached` + comment, reds the run on breach) as the
deadline nears. The autonomous loop ships rebuild-fixable improvements
**immediately** as patch releases — even while a deeper fix is still in review —
and auto-ships a merged source fix on the next daily cycle, so the binding
constraint is human PR-review latency, not release cadence.

**Slack alerting (SLA lifecycle → #alert):** every SLA transition (drift
detected, clock started, at-risk, breached + daily countdown, recovery,
watch-errored) and every automation-authored review request (fix PR /
needs-human issue / interim release) posts to the Slack #alert channel.
Transport is `scripts/slack-alert.sh` (`SLACK_ALERT_WEBHOOK_URL` secret;
everything **no-ops if unset**; delivery is best-effort and never fails a
watch — the GitHub issue + labels stay the durable SLA record). Drift/SLA
alerts are emitted inline by `scout-drift.yml` (its issue is created with the
default `GITHUB_TOKEN`, whose events can't trigger workflows); Claude-App-
authored events go through `slack-alerts.yml`. Verify wiring with
`make slack-test`.

**Scout enrollment is code-driven — never hand-toggle it in the Hub UI.**
`scripts/scout-setup.sh` (`make scout-setup` / `make scout-check`) reconciles
Docker Scout repo enablement with `scout-required-images.json`, and the daily
drift watch runs it first as a self-heal (an un-enrolled repo yields NO policy
results and silently falls out of the gates — the July 2026 failure class:
build-go, build-java, nginx-frontend, build-godynamic were each found
disabled). Org **policy configuration** (which policies gate, license lists,
disabling a policy) has **no public API or CLI** — Docker Scout dashboard only
(policy details page → Edit/Disable).

**When a Scout finding (CVE or policy) needs fixing, follow the `/scout-fix`
skill — it captures exactly how #71/#72, #74, #76, #77, #78 were resolved, plus
the strictly-better republish (section F) and the SLA.** Verify with
`/verify-scout` before opening a PR.

## Critical rules

1. **Never push to `main`; never self-merge.** Branch, PR, human review. `main`
   is protected: the strict-image gates are required checks and a human approving
   review is required, so **automation (the upkeep agent) opens PRs but a human
   merges them** — the bot runs as a GitHub App with no bypass. **Releases:**
   automation may **auto-cut _patch_ releases** that rebuild current `main` into a
   strictly-better published image (a fresh base/OS refresh, or a fix already merged
   via a reviewed PR) — `scripts/next-patch-version.sh` keeps it patch-only, nobody
   pins `:latest` (consumers pin `BUILDENV_TAG=vX.Y.Z`), and these interim releases
   ride a **report-only** grade gate (`publish.yml` `release-meta` detects
   `claude[bot]`) with the daily drift watch + SLA escalation as the enforcement.
   **Human-cut releases stay hard grade-A; minor/major, and any UNREVIEWED source
   change, stay human.** Required-checks list + apply command:
   [docs/BRANCH_PROTECTION.md](docs/BRANCH_PROTECTION.md).
2. **Pin, don't float, security-driven dep bumps in from-source tool builds.**
   The `go get …@vX` transitive pins in the Dockerfiles exist to clear specific
   CVEs; keep them explicit and annotated. See `/scout-fix`.
3. **Keep published-image changes non-breaking.** Regular security upkeep is
   version bumps that don't change an image's runtime contract. Changing a
   published image's default `USER`, entrypoint, or base ABI can break downstream
   `FROM`/`docker run` consumers — that's a coordinated breaking release (the #78
   non-root migration was the last one), not routine maintenance. Prefer the
   minimal patch/minor bump; escalate a major/contract-changing bump for review.
4. **Pin GitHub Actions to SHAs** (Dependabot `actions` group keeps them current).
5. **Keep logic out of workflow YAML.** Non-trivial logic goes in `scripts/`
   (`*.sh`, or `*.cjs` loaded by `actions/github-script` via
   `require('./scripts/<name>.cjs')`) where it can be linted, unit-tested, and
   run standalone; workflow steps stay thin shims. Operator-relevant scripts
   also get a root `Makefile` target (e.g. `make slack-test`). Precedents:
   `scripts/scout-cve-gate.sh`, `scripts/scout-drift-sla.cjs`,
   `scripts/slack-alert.sh`.

## Skills

Prescriptive SOPs in `.claude/skills/<name>/SKILL.md`. Scan this table at the
start of a task and follow the matching skill exactly.

| Skill | When to use |
|---|---|
| `/scout-fix` | A Docker Scout CVE or policy finding on a build image needs fixing (CI gate red, drift issue, or a customer report) |
| `/verify-scout` | Before opening a PR that touches an image — confirm the grade-A images are still clean locally |
