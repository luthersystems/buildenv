# buildenv

Common build and run containers for Luther applications.

## Local Testing

Build locally and test with:
```
cd images && make PLATFORMS=$(../scripts/local_platform.sh) DOCKER_BUILDX_OPTS=--load
```
For the above command to work the `jq` tool has to be installed. Otherwise
replace the PLATFORMS variable with your local docker server/engine details
(e.g. "linux/arm64" -- see `docker version`).

and set your `BUILDENV_TAG` in `common.mk` to the below version:
```
make echo:VERSION
```

## Releases

Github actions is configured to push releaes on version tag pushes. Create a
release for the new version via the github UI and it will automatically kick
off the release pipeline.

## Image security policies

The published images are scanned against Docker Scout policies. CI enforces a
grade-A "bill of health" on a defined set of images (below), and two policy
requirements affect how downstream repos consume these images (further down).

### Grade-A bill of health (required image list)

A [Docker Scout health score](https://docs.docker.com/scout/policy/scores/) is a
weighted A–F grade (A = >90% of points) over eight policies: severity-based CVEs
(20), high-profile CVEs (20), supply-chain attestations (15), approved base
images (15), up-to-date base images (10), SonarQube quality gates (10, off by
default), default non-root user (5), and compliant licenses (5).

The set of images that **must** stay grade A is the single source of truth in
[`.github/scout-required-images.json`](.github/scout-required-images.json):

```
build-api  ·  build-go-alpine  ·  service-base-alpine
```

Because the real grade is computed registry-side on the **pushed** image — and
~15 of those points (supply-chain attestations) can only attach on push, so a
PR's local `--load` image can never grade A — CI enforces this in two tiers,
both reading the list above via the `scout-config` job:

| Tier | Workflow | What it gates |
|---|---|---|
| **PR** (every PR) | `build.yml` → `cve-scan` + `non-root-audit` | **fixable CRITICAL/HIGH CVEs** on the required set, plus a **non-root-user audit across all 10 images** — hard-fails only if a required image regresses to root, and reports every other image's status (the 6 root builders are surfaced, not gated). |
| **Release** (tag push) | `publish.yml` → `scout-policy` | the **true grade** on the pushed image: `docker scout policy --exit-code` (covers attestations, approved/up-to-date base images, high-profile CVEs, and licenses on top of the above). **Hard for human-cut releases**; **report-only for automation's interim patch releases** (the `release-meta` job detects a `claude[bot]` author — those ship strictly-better improvements while a deeper fix is still in review, enforced by the daily drift watch + SLA below). |

`cve_net_extra` in the JSON (currently `build-go`) lists extra builder images
that get the fixable CRITICAL/HIGH CVE net only — not the full grade-A gate.

**To require a new service:** add it to `required` in the JSON. First give it a
non-root default `USER` and clean deps, or the very first PR/release will fail
the gate (which is the point). If a release is ever blocked by an *unfixable*
CVE or a newly-added low-weight policy, scope `scout-policy` with
`--only-policy <slug,...>` or temporarily set `continue-on-error: true` — see the
comment on that job in `publish.yml`.

For the strict-image gates to actually **block merges** — and to ensure
automation can open PRs but never merge them — the checks must be marked required
in `main`'s branch protection. The exact required-checks list, settings, and a
one-shot apply command are in
[docs/BRANCH_PROTECTION.md](docs/BRANCH_PROTECTION.md).

### Remediation SLA & continuous improvement

We commit to remediating **fixable** CVEs on the required images within a fixed
window (per the Allianz security request), tracked in
[`.github/scout-required-images.json`](.github/scout-required-images.json)'s sibling
[`.github/scout-sla.json`](.github/scout-sla.json):

| Severity (fixable) | Published-fix deadline |
|---|---|
| Critical | **15 days** |
| High | **30 days** |
| Unfixable (no upstream fix) | exempt — kept on the latest patches, limitation noted on the tracking issue |

The deadline runs from first detection (when the `scout-drift` issue opens). The
**daily** `scout-drift.yml` classifies the worst fixable severity behind any drift,
labels the issue (`sla:critical` / `sla:high`), and **escalates** (`sla:at-risk`,
then `sla:breached` + reds the run) as the deadline nears — so nothing silently
blows the SLA.

How the autonomous loop meets it (see the `/scout-fix` skill, section F):

- **Rebuild-fixable** (stale base digest, newer OS packages) → the agent cuts a
  **patch release immediately**, shipping the improvement the same day. This is
  decoupled from any in-review PR: a strictly-better rebuild ships **even while a
  deeper fix is still pending** (`docker scout compare` gates it to *strictly
  better*; an identical rebuild is skipped, no version churn).
- **Source-fixable** (needs a Dockerfile/dep change) → the agent opens a PR; a
  human reviews/merges **within the SLA**, and the next daily cycle auto-ships it
  as a patch release. The binding constraint is PR-review latency, not cadence.

Because consumers pin `BUILDENV_TAG=vX.Y.Z` (nobody pins `:latest`), an interim
release that improves posture but isn't yet grade A has no consumer blast radius —
so we ship improvements continuously rather than holding them back for a pristine
release. Grade A remains the steady state; the gate that actually ships is
**non-regression** (strictly better than the last release).

### Supply-chain attestations

Every published image carries SBOM + SLSA provenance attestations. These are
attached during the per-arch `buildx build` (gated to tag/push builds in
`images/Makefile`) and the `verify-attestations` job in `publish.yml` fails the
release if any platform is missing either predicate. No action is required
downstream — this is purely a property of the published image.

### Non-root default user (downstream coordination required)

To satisfy Docker Scout's "no default non-root user" policy, the build images
default to a non-root `build` user (uid 1000):

- `service-base-alpine` runs as `nobody` (the prod runtime image).
- `build-api` defaults to `build`; its consumers already run it with
  `-u $(id -u):$(id -g)`, which overrides the default and keeps working.
- `build-go-alpine` defaults to `build`.

**`build-go-alpine` is also used as a `FROM` base in downstream multi-stage
builds** (e.g. `ui-core/Dockerfile-go`, and any repo using the shared
`common.go.mk` + `Dockerfile-go` pattern). Those build stages inherit the
non-root `USER`, but they write **root-owned BuildKit cache mounts**
(`--mount=type=cache,target=/go/pkg/mod` for `go mod download`,
`/root/.cache/go-build`) and `COPY` root-owned sources, so they will fail with
permission-denied unless the build stage re-asserts root:

```dockerfile
FROM $BUILD_IMAGE AS build
USER root          # required: build stage needs to write the root-owned cache mounts
```

The prod stage (`FROM service-base-alpine`) is unaffected and still runs as
`nobody`. **Land this one-line change in every consumer before bumping the
`BUILDENV_TAG` those repos pin to a release carrying the non-root default**, or
their builds will break.
