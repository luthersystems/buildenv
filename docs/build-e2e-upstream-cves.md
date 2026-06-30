# build-e2e upstream CVE backlog

`build-e2e` is **exempt** from the Docker Scout grade-A required set
(`.github/scout-required-images.json` → `exempt`). It is an *assembly* image: it
`COPY`s already-published third-party release artifacts rather than building
them, so the fixable CRITICAL/HIGH CVEs it reports live in those upstream
artifacts, not in this Dockerfile. buildenv cannot patch them here — each
upstream must cut a clean rebuild, then build-e2e re-pins to it.

This file is the actionable backlog for **un-exempting** build-e2e (promote back
to `required` + restore the non-root `USER`). Source scan: PR #87 CI run
`28464125066`, job *CVE scan (build-e2e)* — **70 fixable C/H across 13 packages
(21 CRITICAL, 49 HIGH)**. `git-lfs` is NOT a contributor: build-e2e builds it
from source with `golang.org/x/crypto@0.52.0` + `golang.org/x/net@0.55.0`
pinned (Dockerfile.build-e2e), so it is already clean.

> Per-binary attribution below is inferred from the Go-build signature (two
> distinct toolchains are present: `stdlib 1.22.11` and `stdlib 1.26.1`). To
> attribute each CVE to an exact binary, scan the source images directly:
> `docker scout cves --only-fixed --only-severity critical,high luthersystems/martin:<ver>` (and the same for `shirotester`, `pdfserv`, and the
> `substratehcp` build). All four are candidates for the Go set.

## Group A — Luther-owned Go binaries (20C / 34H)

COPYd into build-e2e from their published images:

| Artifact | Source repo / image | COPY path |
|---|---|---|
| `martin` | `luthersystems/martin` | `/ko-app/martin` |
| `shirotester` | `luthersystems/shirotester` | `/opt/app` |
| `pdfserv` | `luthersystems/pdfserv` | `/ko-app/pdfserv` |
| `substratehcp` | substrate (download.luthersystemsapp.com) | `/usr/local/bin/substratehcp` |

**Remediation:** rebuild each binary with an up-to-date Go toolchain and bump the
shared `golang.org/x/*` / grpc deps, then re-pin build-e2e to the new
`*_VERSION` ARGs. Target the union of fixed versions below (a single bump per
dep clears every observed range).

| Package | Observed ver(s) | Fix to | C | H | CVEs (deduped) |
|---|---|---|--:|--:|---|
| Go toolchain (`stdlib`) | 1.22.11, 1.26.1 | **≥1.25.11 (or 1.26.4)** | 2 | 26 | CVE-2025-22871, -58187, -58188, -61723, -61725, -61726, -61729, -68121, CVE-2026-25679, -32280, -32281, -32283, -33810, -33811, -33814, -39820, -39836, -42499, -42504 |
| `golang.org/x/crypto` | 0.25.0, 0.47.0 | **0.52.0** | 15 | 6 | CVE-2024-45337, CVE-2025-22869, -47913, CVE-2026-39829, -39830, -39831, -39832, -39833, -39834, -42508, -46595, -46597 |
| `golang.org/x/net` | 0.27.0, 0.48.0 | **0.55.0** | 2 | 2 | CVE-2026-33814, -39821 |
| `google.golang.org/grpc` | 1.65.0 | **1.79.3** | 1 | 0 | CVE-2026-33186 |

## Group B — third-party npm via `newman` (1C / 15H)

build-e2e runs `npm i -g newman` (martin's runtime dep). Every package below is
in newman's transitive dependency tree (a couple may also be bundled inside
`npm` itself).

**Remediation (upstream):** newman (`postman/newman`) cuts a release whose
lockfile resolves these to the fixed versions. **Faster buildenv-side
mitigation if upstream lags:** pin newman to latest and add npm `overrides` for
the six packages at the `npm i -g newman` step — that is editable here without
waiting on postman.

| Package | Observed | Fix to | C | H | CVEs |
|---|---|---|--:|--:|---|
| `handlebars` | 4.7.8 | **4.7.9** | 1 | 4 | CVE-2026-33937, -33938, -33939, -33940, -33941 |
| `node-forge` | 1.3.1 | **1.4.0** | 0 | 6 | CVE-2025-12816, -66031, CVE-2026-33891, -33894, -33895, -33896 |
| `flatted` | 3.2.6 | **3.4.2** | 0 | 2 | CVE-2026-32141, -33228 |
| `underscore` | 1.12.1 | **1.13.8** | 0 | 1 | CVE-2026-27601 |
| `lodash` | 4.17.21 | **4.18.0** | 0 | 1 | CVE-2026-4800 |
| `undici` | 6.26.0 | **6.27.0** | 0 | 1 | CVE-2026-12151 |

## Not gating (MEDIUM, informational)

The full SBOM also reports MEDIUMs (uuid 3.4.0/8.3.2, qs 6.5.5/6.14.2, tar
7.5.15, jose 4.14.4). They are below the C/H gate and listed only so an upstream
bump can sweep them at the same time.

## Done = un-exempt

When Groups A and B both read clean in a build-e2e CVE scan: move `build-e2e`
from `exempt` back into `required` in `.github/scout-required-images.json`, and
restore the non-root `USER build` block in `images/Dockerfile.build-e2e` (the
canonical Ubuntu pattern, uid 1000 is free on the jammy base).
