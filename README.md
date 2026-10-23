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

### Hardening (build-harden)

Every image runs the build-harden kit (`images/harden`, published as
`luthersystems/build-harden`) as the last step of its final stage. The kit
holds each policy as a module and its data; see
[images/harden/README.md](images/harden/README.md) for how other repos use it.
Today it has one policy, `ca-distrust`: the image trusts no CA in
`images/harden/policy/ca-distrust.list`.

That list holds the eMudhra certificates of CVE-2026-111943 (golang/go#82345):
the eight intermediates whose keys leaked, each in its emSign-issued and its
Sectigo "AAA Certificate Services" cross-signed copy (same key), and the
emSign roots above them. The distribution `ca-certificates` packages still
trust the roots, and a store that still trusts AAA (an old certifi, a JDK
cacerts) would accept the cross-signed copies, so removing the roots alone is
not enough.

- The kit removes each listed root from the system bundle and its sources,
  the p11-kit store (Amazon Linux: `awscli`), every other PEM bundle found by
  content (azure-cli's certifi, pip, botocore, google-cloud-cli), and the JDK
  and Debian Java keystores. It blocks every listed certificate in p11-kit,
  each JDK's `blocked.certs` and each NSS database. It fails the build if a
  listed certificate is still trusted, or still verifies against a trust
  store in the image.
- `awscli`, `dind` and `fabric-tools` are the upstream `amazon/aws-cli`,
  `docker:<DIND_VERSION>-dind` and `hyperledger/fabric-tools:2.5.6` images with
  only this step added (for the luthersystems/mars Fabric charts and as the ko
  base image of luthersystems/fabric-snapshot-archiver). `dind` also upgrades
  its Alpine packages and clears a legacy BuildKit cache at start
  (`images/dind-entrypoint.sh`), so it starts on a volume Docker 19.03 used.
- `fabric-baseos` and `fabric-ccenv` are the upstream
  `hyperledger/fabric-baseos` and `hyperledger/fabric-ccenv` images with only
  this step added, one image per Fabric minor, tagged
  `<minor>-<buildenv version>`: `luthersystems/fabric-baseos:2.2-vX.Y.Z` and
  `2.4-vX.Y.Z`, and `luthersystems/fabric-ccenv:2.2-vX.Y.Z`, `2.4-vX.Y.Z` and
  `2.5-vX.Y.Z`. There is no moving tag: a peer pins a release, so an
  automation-cut patch release does not reach it unchosen. A Docker chaincode peer runs its
  chaincode in fabric-baseos and builds it in fabric-ccenv. The 2.2 and 2.4
  bases are Alpine, which still trusts the emSign roots and the AAA
  cross-signs of the leaked intermediates, and Fabric no longer releases
  them. Point the peer at the wrappers in core.yaml (`chaincode.golang.runtime`
  and `chaincode.builder`, or `CORE_CHAINCODE_GOLANG_RUNTIME` and
  `CORE_CHAINCODE_BUILDER`). There is no 2.5 fabric-baseos: upstream has no CA
  bundle. 2.2 and 2.4 are amd64 only, as upstream.
- `make check-harden` (CI `script-tests`) fails when a Dockerfile's final
  stage does not run the kit last, or when a later step can undo it (a
  package step, `update-ca-certificates`, a `COPY --from`, an `ADD`, `curl`,
  `wget`, `unzip`, `tar`, `npm`, an install script, or a COPY into a trust
  store path).
- Each image build in CI (PR and release, amd64 and arm64) then runs
  `images/harden/check/image.sh` on the built image
  (`scripts/ci-harden-check.sh`). `make test-harden` (CI `harden-tests`)
  tests the kit on Debian, Alpine, a JDK and Amazon Linux, and checks that a
  bundle that still trusts AAA, a broken PEM file, a later step that adds a
  root back and an image without the kit all fail.
- The kit is bind-mounted, so it no longer stays in the image: the old
  `/usr/local/sbin/distrust-emudhra.sh` is gone. A downstream image that
  installs or upgrades packages as root runs the kit again last (see
  images/harden/README.md).
- Not covered: a CA list compiled into a binary, such as Node's built-in
  list, is reported, not edited. Node 22.23.4, 24.22.1 and 26.12.1 take
  Mozilla's NSS 3.131.1 list, which drops emSign ECC Root CA - G3, emSign Root
  CA - C1 and emSign ECC Root CA - C3 but keeps emSign Root CA - G1. build-js
  uses Node 24.22.1, so its built-in list keeps G1 (checked with
  `tls.rootCertificates`). A program started with `node --use-openssl-ca`
  reads the system bundle, which has no emSign root. Node 20 is past end of
  life and gets no fix. Go programs built with Go 1.26.10 or later refuse the
  eight intermediates themselves.

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
| **Release** (tag push) | `publish.yml` → `scout-grade` | the **grade** on the pushed image, from `scripts/scout-grade.sh` (see below): fixable C/H and CISA KEV CVEs (VEX-aware), non-root user, SBOM + provenance on every platform, and no AGPL package in the SBOM; outdated base images are reported, not gated. **Hard for human-cut releases**; **report-only for automation's interim patch releases** (the `release-meta` job detects a `claude[bot]` author — those ship strictly-better improvements while a deeper fix is still in review, enforced by the daily drift watch + SLA below). |

`cve_net_extra` in the JSON (currently `build-go`) lists extra builder images
that get the fixable CRITICAL/HIGH CVE net only — not the full grade-A gate.

**To require a new service:** add it to `required` in the JSON. First give it a
non-root default `USER` and clean deps, or the very first PR/release will fail
the gate (which is the point). If a release is ever blocked by an *unfixable*
finding, add an OpenVEX waiver when the code is not reachable, or temporarily
set `continue-on-error: true` on `scout-grade` — see the comment on that job in
`publish.yml`.

**Why CI does not call `docker scout policy` (#150).** `docker scout policy`
and Scout repo enrollment are org-level Scout API calls. CI logs in to Docker
Hub with OIDC only, and neither an OIDC connection nor an organization access
token has a Scout scope, so those calls return 403. Image-level calls
(`docker scout cves`) and registry reads work. So `scripts/scout-grade.sh`
checks each health-score rule from them, and the daily drift watch and the
release gate use it. The grade shown on Docker Hub is Scout's own and does
not change. `docker/scout-action` `quickview` adds a CVE overview to each run
summary (report only). `make scout-setup` still needs a human login.

For the strict-image gates to actually **block merges** — and to ensure
automation can open PRs but never merge them — the checks must be marked required
in `main`'s branch protection. The exact required-checks list, settings, and a
one-shot apply command are in
[docs/BRANCH_PROTECTION.md](docs/BRANCH_PROTECTION.md).

### Remediation SLA & continuous improvement

We commit to remediating **fixable** CVEs on the required images within a fixed
window (per a customer security request), tracked in
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
