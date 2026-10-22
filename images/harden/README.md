# build-harden

A kit that hardens a container image and checks it. Every Luther image runs
it as the last step of its final stage, whatever its base (Alpine, Debian,
Ubuntu, Amazon Linux, a JDK image) and architecture (amd64, arm64). The kit
is only shell scripts and data, with no binaries, and it is published as the
image `luthersystems/build-harden`, tagged with each buildenv release.

Each policy is a module (`modules/<name>.sh`) and its data (`policy/`). A new
incident is usually a change to the data and a new buildenv release; each
repo then bumps one pinned tag.

| Module | Policy | Data |
|---|---|---|
| `ca-distrust` | The image trusts no CA in the list: each listed root is removed from every trust store, and every listed certificate (roots and intermediates) is blocked where the TLS stack has a block list. | `policy/ca-distrust.list`, `policy/ca-distrust/*.pem` |

## Use it in a Dockerfile

Pin the kit by tag and digest, and run it as root after the last step that
installs or upgrades packages or copies files from another stage:

```dockerfile
FROM luthersystems/build-harden:<version>@sha256:<digest> AS harden

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates curl
# ... the rest of the image ...
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
USER nobody
```

The kit is bind-mounted read-only, so no kit file stays in the image. The
build needs BuildKit (the default `docker build` since Docker 23, and every
`docker buildx build`). A Dependabot or Renovate `docker` update of the `FROM`
line bumps the kit.

- The image needs `/bin/sh`, `awk`, `grep`, `sed`, `find`, `base64`,
  `sha256sum` and `mktemp`. Amazon Linux 2023's base image has no `find`:
  install `findutils` first. With `openssl`, the kit also tests that no listed
  intermediate still chains to a root the image trusts; without it, the image
  check below does.
- An image whose final stage has no shell (`FROM scratch`, distroless) runs
  the kit in a build stage and copies the trust stores from it, then runs the
  image check.
- Settings go before `sh` on the same line
  (`... HARDEN_STRICT_BINARIES=1 sh /harden/harden.sh`), so they do not stay
  in the image's environment. `HARDEN_MODULES="ca-distrust"` runs only the
  modules named.
  The kit finds NSS databases anywhere; `HARDEN_NSSDB` names more. `HARDEN_STRICT_BINARIES=1`
  fails the build on a binary that holds a listed certificate (a Node.js
  binary with its CA list compiled in), which by default is only reported.

## Check it in CI

Two checks ship in the kit, under `check/`.

- `check/dockerfile.sh [DIR or FILE ...]` reads each Dockerfile and fails
  when the final stage does not run the kit last, when the kit is not
  mounted from a `luthersystems/build-harden` stage pinned by digest, or when
  a later step can undo it (a package step, a `COPY --from`, an `ADD`, a COPY into a trust
  store).
- `check/image.sh [--platform P] IMAGE` exports the built image and checks
  it on the host (no emulation is needed for another architecture): no file
  holds a listed certificate, no listed certificate verifies against any
  trust store in the image, the system bundle is not empty, every Java
  keystore and `blocked.certs` and every NSS database is right. It needs
  `docker`, `openssl` and `bash` on the host, plus `keytool` for an image
  with a Java keystore and `certutil` (libnss3-tools) for one with an NSS
  database.

Copy the kit out of the pinned image to run them:

```sh
kit=$(sed -n 's/^FROM \(luthersystems\/build-harden[^ ]*\) AS harden$/\1/p' Dockerfile)
cid=$(docker create "$kit" /nonexistent)
docker cp "$cid:/harden" .harden && docker rm "$cid"
bash .harden/check/dockerfile.sh Dockerfile
bash .harden/check/image.sh --platform linux/arm64 my-image:arm64
```

## Add a CA to the list

1. Get the certificate from a source you can check (crt.sh, the CA's
   incident report, Mozilla's bug). List every copy of the key: a
   cross-signed certificate is another certificate, and a chain through it
   is refused only when it is listed too.
2. Save it as `policy/ca-distrust/<name>.pem` and add a line to
   `policy/ca-distrust.list` with its SHA-256 (of the DER), `root` or
   `intermediate`, the file name and the source, under a comment that names
   the incident.
3. `make test-harden` and the image builds check it. The kit checks each PEM
   against its listed fingerprint before it uses it.

## What each store gets

| Store | Root | Intermediate |
|---|---|---|
| `/usr/share/ca-certificates` and `/usr/local/share/ca-certificates` (Debian, Ubuntu, Alpine) | removed, deselected in `/etc/ca-certificates.conf`, bundle rebuilt | removed if present |
| p11-kit (`/etc/pki/ca-trust`: Red Hat, Amazon Linux) | blocklisted | blocklisted |
| Any other PEM file (system bundle, certifi, pip, botocore, the AWS CLI, gcloud) | removed, found by content | removed if present |
| Java `cacerts` | removed | none |
| Java `lib/security/blocked.certs` | blocked | blocked |
| NSS databases (`/etc/pki/nssdb`, `~/.pki/nssdb`, `HARDEN_NSSDB`) | trust `p,p,p` | trust `p,p,p` |
| A binary with a compiled-in CA list | reported | reported |

A client with no block list (curl, git or Python on Debian or Alpine) is safe
while no trust store in the image holds the root that issued a listed
intermediate. The kit and the image check fail when one does.
