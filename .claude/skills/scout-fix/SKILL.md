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
| Policy: **default non-root user** | already satisfied; only when a NEW image joins the set | **D** |
| Policy: **supply-chain attestations** | already wired in Makefile/CI; not a Dockerfile fix | **E** |
| Policy: **outdated base image** (stale published digest, the #80 class) | nothing to edit — cut a PATCH release to rebuild/republish | **F** |

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

## D — Policy: default non-root user (already satisfied — rarely a fix step)

The three required images are **already non-root**: `build-api` and
`build-go-alpine` default to user `build` (uid 1000), `service-base-alpine` to
`nobody` (#78). A routine CVE fix never touches this; the PR-time `non-root-audit`
job statically checks **every** image's final-stage USER and hard-fails only if a
*required* one regresses to root (the other images — 6 currently default to root
— are reported, not gated, since making them non-root is a breaking change for
their consumers). **Don't re-add what's already there.**

You apply this pattern only when a **brand-new image joins the required set**.
Then add a uid-1000 user **after all privileged setup** (`apk add`/`apt`, `git
config --system`, `ssh-keyscan`, root-owned `COPY`s), give it a writable `HOME`,
and `USER` it — Debian: `useradd --create-home --uid 1000 --user-group build`;
Alpine: `addgroup -g 1000 build && adduser -D -u 1000 -G build -h /home/build
build`. Go caches stay writable because `/go` is mode 1777 and `GOCACHE=/tmp`
is 1777.

The non-root migration was a **one-time coordinated breaking change** — because
`build-go-alpine` is a `FROM` base, consumers had to add `USER root` to their
build stages first (#78) — and it is **complete**. Don't reintroduce that class
of change in a routine fix; see "keep fixes non-breaking" in Guardrails.

---

## E — Policy: supply-chain attestations (already wired — not a Dockerfile fix)

SBOM + SLSA provenance (15 pts) are **already produced** by the Makefile
(`DOCKER_ATTEST_OPTS=$(if $(GIT_TAG),--provenance=mode=max --sbom=true,)`, gated
on `GIT_TAG`) and only attach on push — the `--load` exporter rejects them. So
you can't satisfy this on a PR build, and you **never** add
`--sbom`/`--provenance` to a `--load` build (it breaks the local build). There's
no Dockerfile edit here (#78).

If the attestations policy fails on a *published* image, it's a `push-manifests`
regression (buildx `imagetools create` dropping attestation manifests), not a
finding you fix in `images/` — the `verify-attestations` job in `publish.yml`
already guards it. Inspect with `docker buildx imagetools inspect
luthersystems/<img>:<ver> --raw` (expect per-platform in-toto manifests).

---

## F — Policy: outdated base image (stale published digest — republish, don't edit)

This is the **#80 class**, and the one finding whose remedy is a **rebuild, not a
source edit**. The published image embeds a base-image **digest** that has since
gone stale: Docker periodically **re-pushes a floating base tag** (e.g.
`golang:1.26.4`) onto a freshly-patched OS, so the tag now resolves to a newer
digest than the one baked into the published image. Scout's "No outdated base
images" policy flags it. The Dockerfile already pins the base by floating tag, so
**there is nothing to change in `images/`** — a fresh build resolves the new
digest on its own.

**Confirm it's really this class** (run against the published image, not a local
build — the drift is in what's published):
```bash
docker scout policy          "luthersystems/<img>:latest" --org luthersystems   # which policy failed?
docker scout recommendations "luthersystems/<img>:latest"                       # expect "Refresh base image / Tag was pushed more recently"
docker scout cves            "luthersystems/<img>:latest" --only-fixed --only-severities critical,high   # must be empty
```
You are in section F **only if** the *sole* failing policy is "No outdated base
images", AND there are no fixable C/H CVEs, AND `common.config.mk` is already on
the latest base patch (so B doesn't apply). If a real fixable CVE or a version
bump is *also* needed, that part takes the A/B/C → PR path; F is purely the
"nothing to edit, just republish" remedy.

**Remedy — cut the next PATCH release (automation is allowed here):**
A plain rebuild off unchanged source picks up the fresh base digest, and the only
way to rebuild + republish in this repo is the release pipeline. So cut the next
**patch** tag and let `publish.yml` do the rest (build every image, push,
attestations, refresh `:latest` **and** the new `:vX.Y.Z`, then re-run the true
`scout-policy` grade gate):
```bash
next=$(scripts/next-patch-version.sh)     # ALWAYS a patch bump, e.g. v0.1.5 -> v0.1.6
gh release create "$next" --target main --title "$next" \
  --notes "Automated base-image refresh: rebuild to pick up refreshed upstream base digests and restore Docker Scout grade A on the required images. No source changes."
```

Why this is safe to do **unattended**: it's a no-source-change rebuild; it's
**patch-only** (minor/major imply a contract change and stay human — CLAUDE.md
rule 1/3); nobody consumes `:latest` (consumers pin `BUILDENV_TAG=vX.Y.Z`), so the
blast radius is nil; and `publish.yml`'s `scout-policy` gate is the backstop — if
the rebuild doesn't reach grade A the release run reds and re-flags the issue.

**Always pick the version with `scripts/next-patch-version.sh`** — never hand-type
a tag. It refuses anything but a clean patch increment, which is what keeps
automation inside the patch-only lane. After cutting the release, **do not open a
PR** (there is no diff): note on the `scout-drift` issue that you cut `<tag>` to
republish, and let the release run close it out.

---

## Step N — Verify, then PR (sections A–D) — or release (section F)

**Section F (republish only)** has no diff to verify: you already confirmed the
class, cut the patch release, and `publish.yml`'s gate is the check. Skip the rest
of this step.

**Sections A–D (a real source change):**

1. Rebuild every image you touched and run **`/verify-scout`** — the grade-A
   images must show **0 fixable CRITICAL/HIGH** and a non-root `USER`.
2. If you bumped `common.config.mk`, rebuild **every** image that consumes that
   ARG (a Go bump touches all Go images), not just the one that flagged.
3. Open a PR. The `cve-scan` gate re-runs your check; the release `scout-policy`
   gate enforces the true grade on the pushed image. A human merges. Cutting the
   release that ships the fix stays human for a source change (it may warrant more
   than a patch bump) — only the **section-F** no-source-change refresh is
   auto-released, and only ever as a patch.

## Guardrails — when to stop and ask

- **Never pin a transitive dep *lower* than a sibling already requires** — it
  won't build. Re-read rule C.2.
- **Never satisfy a policy by weakening posture** (e.g. removing the non-root
  `USER`, disabling the gate, adding to an allowlist) to make CI green. Fix the
  finding.
- **Auto-release stays in the patch lane (section F only).** The only release
  automation may cut unattended is the section-F no-source-change base refresh,
  and only via `scripts/next-patch-version.sh` (which emits a patch bump or
  refuses). Never auto-cut a minor/major, never auto-cut a release that carries a
  source change, and never hand-pick a tag to route around the script. Anything
  that seems to need more than a patch republish is a human decision — stop and
  escalate on the issue.
- **Unfixable CVE (no `--only-fixed` hit, no upstream fix yet):** there's no
  clean bump. Don't force one. Record it (the non-blocking SARIF/quickview steps
  already track totals) and, if it blocks a release policy, surface it to a human
  with the CVE id and why no fix exists — don't broaden `--only-policy` silently.
- **Keep fixes non-breaking — this is the maintenance contract.** Regular Scout
  upkeep is version bumps (A/B/C) that don't change a published image's runtime
  contract. Do **not** alter a published image's default `USER`, `ENTRYPOINT`,
  base distro/ABI, or anything a downstream `FROM`/`docker run` consumer relies
  on as part of a fix — that's a coordinated breaking release (the one-time #78
  non-root migration was the last one), not routine work. If clearing a finding
  seems to require it, stop and escalate to a human.
- **Prefer the minimal bump that clears the finding.** Patch/minor bumps of a
  base or tool are low-risk and are what regular maintenance normally applies
  automatically — but watch a tool bump that changes *behavior* even without a
  major (e.g. `golangci-lint` surfacing new lint in consumer CI); apply the
  minimal version that clears the finding. A **major** bump (alpine/golang major,
  a tool's vN→vN+1, Node major) can change behavior, CLI flags, or ABI that
  downstream consumers depend on — treat it as potentially breaking: take it only
  if no patch/minor clears the finding, and flag it for human review instead of
  auto-merging.
