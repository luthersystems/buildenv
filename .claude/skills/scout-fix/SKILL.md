---
name: scout-fix
description: "Resolve a Docker Scout finding (a CVE or a failed policy) on a build image and restore its grade-A bill of health. Use when a CI Scout gate is red, the weekly scout-drift issue fires, or a customer (e.g. Allianz) reports a Scout policy finding. Captures how #71/#72, #74, #76, #77, #78 were fixed. Examples: 'fix the fixable HIGH CVE in build-go-alpine', 'service-base-alpine dropped below grade A', 'clear the x/sys CVE in the go tools'."
---

# Fix a Docker Scout finding on a build image

This is the playbook that produced PRs #71/#72 → #78 (build-api, build-go-alpine,
service-base-alpine to a clean grade-A Docker Scout health score). Follow it
whenever a Scout finding needs clearing. **Most fixes are a version bump in one
place; the hard ones are transitive Go pins — both patterns are below.**

> Background on the grade and where the gates live: README "Image security
> policies" and [CLAUDE.md](../../../CLAUDE.md). The required set is
> `.github/scout-required-images.json`.

## Step 0 — Reproduce and classify (always do this first)

Build the image locally and look at the real finding. Never fix blind from a CI
log alone.

```bash
cd images
img=build-go-alpine                       # the affected image
make PLATFORMS=linux/amd64 DOCKER_BUILDX_OPTS=--load "$img"
ref="local://luthersystems/${img}:$(git rev-parse HEAD)"

docker scout quickview  "$ref"            # C/H/M/L counts + which policies pass
docker scout cves       "$ref" --only-fixed --only-severities critical,high   # the PR hard gate
docker scout cves       "$ref" --details --only-fixed   # package + fixed-in version per CVE
docker scout recommendations "$ref"       # base-image freshness suggestions
```

Read the output and classify the finding into exactly one of the five rows
below, then jump to that section. A `quickview` policy line tells you policy
findings; `cves` tells you CVE findings.

| Finding | Fix pattern | Section |
|---|---|---|
| Fixable CVE in an **OS package** (apt/apk) | upgrade OS packages (escape hatch: pull one pkg from edge) | **A** |
| CVE that only the **base image** carries | bump the central base version | **B** |
| Fixable CVE in a **bundled Go tool** (golangci-lint, buf, swagger, git-lfs, gotestsum…) | from-source build + pin the patched transitive dep | **C** |
| Policy: **default non-root user** | add a non-root `USER` (+ downstream check) | **D** |
| Policy: **supply-chain attestations** | Makefile attestation opts (release-only) | **E** |

---

## A — OS package CVE (apt / apk)

The fix is to pull patched OS packages at build time. Consolidate into the
existing setup `RUN` so package lists are valid, and clean the cache.

**Debian/Ubuntu base** (build-api, build-go, build-e2e) — `apt`:
```dockerfile
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      <packages> && \
    rm -rf /var/lib/apt/lists/*
```

**Alpine base** (build-go-alpine, build-godynamic, service-base-alpine) — `apk`:
```dockerfile
RUN apk update && apk upgrade --no-cache && apk add --no-cache <packages>
```

**Escape hatch — fix only in alpine `edge`** (real example: jq 1.8.1-r0 carried
fixable HIGH CVE-2026-32316 / CVE-2026-40164; the fix 1.8.2-r0 shipped in edge
before 3.24 stable, #76). Pull *only that package* from a tagged edge repo and
leave a revert note:
```dockerfile
# jq: patched jq (>=1.8.2-r0) is only in alpine edge; 3.24 stable still ships
# vulnerable 1.8.1-r0. Pull jq (only) from edge until backported, then drop this.
RUN echo "@edge https://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories && \
  apk add --no-cache jq@edge
```
The `@edge` tag scopes edge to that one package; everything else stays stable.
**Record the revert condition in a comment** so it's removed once stable catches up.

---

## B — Base image CVE

If the CVE is in the base layer itself, bump the **central** version in
`common.config.mk`, then the matching `ARG <X>=<default>` fallbacks in the
Dockerfiles that declare them. Confirm the new base actually clears it before
committing (real example #76: alpine 3.23 → 3.24 cleared a lingering medium):

```bash
docker scout quickview alpine:3.24
docker scout quickview golang:1.26.4-alpine3.24
```

`common.config.mk` is the source of truth; CI always builds with it. Update the
`ARG` defaults too so a bare local `docker build` doesn't regress. No apk/apt
package is version-pinned, so minor base bumps resolve cleanly.

---

## C — Bundled Go tool CVE (the from-source pin pattern)

The gated images build CLI tools (golangci-lint, buf, go-swagger, git-lfs,
gotestsum, go-bindata) from Go modules. A released tool often bundles a
**vulnerable transitive dep** (commonly `golang.org/x/sys`, `x/crypto`, `x/net`,
or `quic-go`). The fix is to build the tool **from source in a throwaway module**
and `go get` a **patched** version of the transitive dep before building.

Pattern (mirror the existing blocks in `Dockerfile.build-api` /
`Dockerfile.build-go-alpine`):
```dockerfile
ARG GOLANGCI_LINT_VERSION
RUN mkdir /tmp/golangci && cd /tmp/golangci && \
    go mod init _golangci && \
    go get "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v${GOLANGCI_LINT_VERSION}" golang.org/x/sys@v0.45.0 && \
    go build -ldflags "-X main.version=${GOLANGCI_LINT_VERSION} -X main.commit=unknown -X main.date=unknown" \
      -o /go/bin/golangci-lint "github.com/golangci/golangci-lint/v2/cmd/golangci-lint" && \
    cd / && rm -rf /tmp/golangci
```

Rules learned the hard way (#77):

1. **If the tool is currently `go install`-ed, convert it to from-source** so you
   can pin the transitive. `go install` gives you no control over transitive deps.
2. **Pick the pin version to avoid a downgrade conflict.** Pin to the *highest*
   patched version any sibling dep already requires, not the bare "fixed-in".
   Example: pin `x/sys@v0.45.0` (not the 0.44.0 "fixed-in") because
   `x/crypto@v0.52.0` and `x/net@v0.55.0` already require 0.45.0 — pinning lower
   fails to build. After editing, the explicit pin is often defensive (the tool
   may already get the patched dep transitively); keep it explicit anyway so the
   gate can't regress silently.
3. **Preserve `--version` where it matters.** golangci-lint reads build-info only
   when `main.date` is empty, so the `-X main.version=…` ldflags keep `--version`
   correct. gotestsum has no version ldflag and derives its version from the main
   module, so from-source it reports `(devel)` — cosmetic, leave a comment.
4. **Apply across every gated image that ships the tool** (build-api, build-go,
   build-go-alpine, build-godynamic). `service-base-alpine` bundles no Go tools.
5. **Leave a comment with the CVE id** next to the pin (e.g. `# CVE-2026-39824`,
   `quic-go@v0.59.1 # CVE-2026-40898`) so the next reader knows why it's pinned
   and when it can be dropped.

---

## D — Policy: default non-root user

Scout's "default non-root user" policy (5 pts) wants a non-root default `USER`.
Add a uid-1000 user **after all privileged setup**, point `HOME` at a writable
dir, then `USER` it (#78).

Debian (build-api):
```dockerfile
RUN useradd --create-home --uid 1000 --user-group build
ENV HOME=/home/build
USER build
```
Alpine (build-go-alpine):
```dockerfile
RUN addgroup -g 1000 build && adduser -D -u 1000 -G build -h /home/build build
ENV HOME=/home/build
USER build
```

Checks before you commit:
- **Placement:** `USER` must come *after* every `apk add` / `apt`, `git config
  --system`, `ssh-keyscan`, and `COPY` of root-owned files.
- **Writability:** Go needs writable GOPATH/cache. The official golang image
  ships `/go` mode 1777 and these images set `GOCACHE=/tmp` (1777), so non-root
  module/build-cache writes work. Verify: run the image and write the caches.
- **⚠️ Downstream `FROM`-base coordination (the #78 footgun).** `build-go-alpine`
  is used as a `FROM` base in downstream multi-stage builds (ui-core
  `Dockerfile-go`, anything on the shared `common.go.mk` pattern). Those build
  stages **inherit this `USER`** and then fail writing the root-owned BuildKit
  cache mount (`/go/pkg/mod`) or running `apk add`. Each consumer must add
  `USER root` to its build stage first. **Land those downstream changes (and
  document the requirement in README) BEFORE releasing a tag that carries this.**
  The prod stage (`FROM service-base-alpine`) is unaffected — it stays `nobody`.

---

## E — Policy: supply-chain attestations

SBOM + SLSA provenance attestations (15 pts) are produced by the Makefile and
**only attach on push to a registry** — the local `--load` exporter rejects
them. So this is a *release-time* property, not something you can satisfy on a PR
build (#78). The wiring already exists:

```makefile
DOCKER_ATTEST_OPTS=$(if $(GIT_TAG),--provenance=mode=max --sbom=true,)
```

If attestations are missing on a published image, the bug is in the
**`push-manifests`** step (buildx `imagetools create` can drop attestation
manifests when recombining the multi-arch index), not in a Dockerfile. The
`verify-attestations` job in `publish.yml` guards this. Verify by hand with:
```bash
docker buildx imagetools inspect luthersystems/<img>:<ver> --raw   # expect per-platform in-toto manifests
```
Do **not** try to add `--sbom`/`--provenance` to `--load` builds; that breaks the
local build for everyone.

---

## Step N — Verify, then PR

1. Rebuild every image you touched and run **`/verify-scout`** — the grade-A
   images must show **0 fixable CRITICAL/HIGH** and a non-root `USER`.
2. If you bumped `common.config.mk`, rebuild **every** image that consumes that
   ARG (a Go bump touches all Go images), not just the one that flagged.
3. Open a PR. The `cve-scan` gate re-runs your check; the release `scout-policy`
   gate enforces the true grade on the pushed image. A human cuts the tag.

## Guardrails — when to stop and ask

- **Never pin a transitive dep *lower* than a sibling already requires** — it
  won't build. Re-read rule C.2.
- **Never satisfy a policy by weakening posture** (e.g. removing the non-root
  `USER`, disabling the gate, adding to an allowlist) to make CI green. Fix the
  finding.
- **Unfixable CVE (no `--only-fixed` hit, no upstream fix yet):** there's no
  clean bump. Don't force one. Record it (the non-blocking SARIF/quickview steps
  already track totals) and, if it blocks a release policy, surface it to a human
  with the CVE id and why no fix exists — don't broaden `--only-policy` silently.
- **A base-image major bump that breaks the build** (musl/glibc, tool incompat)
  is a judgment call — fix forward if straightforward, else stop and ask.
- **Touching `build-go-alpine`'s `USER` or base** ripples to downstream repos.
  Confirm the downstream coordination (section D) is done before a release.
