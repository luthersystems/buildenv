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

Three images **must** stay at Docker Scout grade A:
`build-api`, `build-go-alpine`, `service-base-alpine`. The required set is the
single source of truth in
[`.github/scout-required-images.json`](.github/scout-required-images.json) and is
gated in CI three ways:

| When | Workflow | Gate |
|---|---|---|
| every PR | `build.yml` → `cve-scan` | fixable CRITICAL/HIGH CVEs + default-non-root-user |
| release (tag) | `publish.yml` → `scout-policy` | `docker scout policy --exit-code` (true grade) + attestations |
| weekly cron | `scout-drift.yml` | re-scan published `:latest`; opens a `scout-drift` issue on drift |

**When a Scout finding (CVE or policy) needs fixing, follow the `/scout-fix`
skill — it captures exactly how #71/#72, #74, #76, #77, #78 were resolved.**
Verify with `/verify-scout` before opening a PR.

## Critical rules

1. **Never push to `main`.** Branch, PR, human review. Releases are tagged by a
   human (a base-image change can require coordinated downstream edits — see #78
   and the non-root note in README).
2. **Pin, don't float, security-driven dep bumps in from-source tool builds.**
   The `go get …@vX` transitive pins in the Dockerfiles exist to clear specific
   CVEs; keep them explicit and annotated. See `/scout-fix`.
3. **Respect the non-root downstream contract.** `build-go-alpine` is a `FROM`
   base; changing its default `USER` can break consumers' build stages. See #78.
4. **Pin GitHub Actions to SHAs** (Dependabot `actions` group keeps them current).

## Skills

Prescriptive SOPs in `.claude/skills/<name>/SKILL.md`. Scan this table at the
start of a task and follow the matching skill exactly.

| Skill | When to use |
|---|---|
| `/scout-fix` | A Docker Scout CVE or policy finding on a build image needs fixing (CI gate red, drift issue, or a customer/Allianz report) |
| `/verify-scout` | Before opening a PR that touches an image — confirm the grade-A images are still clean locally |
