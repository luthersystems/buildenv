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
| `ca-distrust` | The image trusts no CA in the list: each listed root is removed from every trust store, and every listed certificate (roots and intermediates) is blocked where the TLS stack has a block list. The image still trusts each CA in the keep list (the positive control, below). | `policy/ca-distrust.list`, `policy/ca-distrust/*.pem`, `policy/ca-keep.list`, `policy/ca-keep/*.pem` |

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
  fails the build on a binary or program source file that holds a listed
  certificate (a Node.js binary with its CA list compiled in, a `.js` root
  list in `node_modules`), which by default is only reported.

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
  keystore and `blocked.certs` and every NSS database is right, and each kept
  CA is still trusted (the positive control, below). It needs
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

## Clients with their own roots

A clean trust store does nothing for a client that does not read it. The
image check fails unless the image's environment points each such client at
the system store (lessons of connectorhub#262, hyphae#71/#72, mars#306):

| Client | Its own roots | What the image must do |
|---|---|---|
| Node.js | a list built into `node` (holds the emSign roots, and AAA in some versions) | `ENV NODE_OPTIONS=--use-openssl-ca SSL_CERT_FILE=<system bundle>`. Without `SSL_CERT_FILE` an official Node binary trusts no root (its OpenSSL looks in its own directory). `--use-system-ca` does not count: it adds the system store to the built-in list, which keeps the emSign roots (tested on Node 22.23) |
| uv / uvx | a list built into `uv`; uvx installs a fresh certifi when it runs | `ENV SSL_CERT_FILE=<system bundle>` and `ENV REQUESTS_CA_BUNDLE=<system bundle>` (also `CURL_CA_BUNDLE`, `HTTPLIB2_CA_CERTS`, `GRPC_DEFAULT_SSL_ROOTS_FILE_PATH` where used) |
| Chrome / Chromium | the Chrome Root Store built into its binary; distrust only from `$HOME/.pki/nssdb` | ship an NSS database (the kit distrusts the list in it) and copy it to `$HOME/.pki/nssdb` when the program starts, then check that Chrome opens it (hyphae `pdfserv/pdfgen/nssdb.go`) |
| Any binary with DER roots (Go `x509roots/fallback`, ...) | compiled in | reported; `--strict-binaries` fails |

An image with no system bundle fails the check (node:alpine ships none:
install `ca-certificates` before the kit); pass `--min-roots 0` for an
image with no TLS client.

Limits: code that reads a root list directly (`tls.rootCertificates`,
`certifi.where()`, a vendored `.js` root list) gets past every ENV setting,
and a package installed at run time is not hardened. The checks are static:
a repo whose image runs a TLS client should keep a behavioural test (a local
TLS server with a fresh CA: fails without the CA, passes with it in the
bundle, fails with the override cleared; and, where the network allows,
refusal of emSign's test sites `testevg1.emsign.com` / `testevc3.emsign.com`).

## The positive control

The checks of `ca-distrust.list` prove that the listed CAs fail. A trust
store that lost more than the list (an emptied bundle, a stripped root the
policy did not name) passes them too, so they alone cannot tell a correct
block from one that breaks every TLS call. `policy/ca-keep.list` names CAs
that must stay trusted: the USERTrust RSA and ECC roots, which today's
Sectigo chains end at, and a Sectigo intermediate that each one issued.
AAA Certificate Services, the older Sectigo root that cross-signed the leaked
eMudhra intermediates, is distrusted; these are not.

| Store | Kept root | Kept intermediate | Checked by |
|---|---|---|---|
| Every PEM file with 100 or more certificates (the system bundle, certifi, pip), and the file `SSL_CERT_FILE` or `REQUESTS_CA_BUNDLE` names | needed by the intermediate | verifies against the file (`openssl verify`) | the module (when the image has `openssl`) and the image check |
| Java `cacerts` | still in it | none | the module and the image check |
| Java `blocked.certs` | not blocked | not blocked | the module and the image check |
| NSS databases | not distrusted, by certificate or key | not distrusted | the image check |

Go, Node.js (with `--use-openssl-ca`), uv, Python requests, curl and git read
the system bundle or the file `SSL_CERT_FILE` names, so a chain that verifies
there verifies for them. A CA in both lists is a broken policy: the module and
the image check refuse it. `make test-harden` proves each check fails when a
kept CA is lost (the `keep-*` fixtures).

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
| A binary with a compiled-in CA list, or program source (`.go`, `.js`, `.py`, ...: a Go module cache, a vendored library) | reported, not edited | reported, not edited |

A client with no block list (curl, git or Python on Debian or Alpine) is safe
while no trust store in the image holds the root that issued a listed
intermediate. The kit and the image check fail when one does.
