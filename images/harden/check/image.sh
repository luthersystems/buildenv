#!/usr/bin/env bash
# Check that a built image holds every build-harden policy.
#
# Why: harden.sh checks its own work while the image builds, but a later
# Dockerfile step (a package upgrade, a COPY --from, a tool that brings its own
# CA bundle) can undo it. This check runs on the finished image, so the
# result is proved on what ships.
#
# How: the image's file system is exported (docker create + docker export, so
# the image needs no shell or tools, and an image of another architecture
# needs no emulation) and every check runs on the host, with the host's
# openssl, keytool and certutil, so a broken tool in the image cannot make it
# pass. For the ca-distrust policy:
#
#   - no PEM file in the image holds a listed certificate (each block's DER
#     sha256 is compared with the list, whatever the file's name or layout);
#   - no listed certificate verifies (openssl verify) against any PEM file in
#     the image, so a leaked intermediate cannot chain to a root that is still
#     trusted, such as one that cross-signed it;
#   - the system bundle still holds at least --min-roots roots (default 100),
#     so an emptied trust store fails instead of passing as clean;
#   - no Java cacerts keystore holds a listed certificate, and every JDK's
#     lib/security/blocked.certs blocks every one;
#   - every NSS database distrusts every listed certificate (trust p,p,p).
#
#   - the image's environment points each client with its own root list at
#     the system store: Node (NODE_OPTIONS=--use-openssl-ca and
#     SSL_CERT_FILE), uv
#     (SSL_CERT_FILE, REQUESTS_CA_BUNDLE), and Chrome needs an NSS database;
#   - an image with no system bundle fails (--min-roots 0 allows it).
#
# A binary or program source file that holds a listed certificate, as PEM
# text or as its public key in DER (a built-in root list), is reported, and
# fails with --strict-binaries. The DER search needs python3 on the host.
#
# Usage: image.sh [--platform P] [--min-roots N] [--strict-binaries]
#                 [--allow PATH_GLOB]... IMAGE
# --allow skips a file (in the image's paths) for every check; give the
# reason in the caller, where a reviewer sees it.
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
LIST=$KIT/policy/ca-distrust.list
CERTS=$KIT/policy/ca-distrust
P11_TRUST=/etc/pki/ca-trust/extracted/openssl/ca-bundle.trust.crt

platform=
min_roots=100
strict_binaries=0
allow=()
while [ $# -gt 0 ]; do
	case $1 in
	--platform) platform=$2; shift 2 ;;
	--min-roots) min_roots=$2; shift 2 ;;
	--strict-binaries) strict_binaries=1; shift ;;
	--allow) allow+=("$2"); shift 2 ;;
	-*) echo "image.sh: unknown option $1" >&2; exit 2 ;;
	*) break ;;
	esac
done
IMAGE=${1:?usage: image.sh [options] IMAGE}

for tool in docker openssl awk sha256sum tar; do
	command -v "$tool" >/dev/null || { echo "image.sh: needs $tool" >&2; exit 2; }
done

work=$(mktemp -d)
cid=
cleanup() {
	local rc=$?
	[ -z "$cid" ] || docker rm -f "$cid" >/dev/null 2>&1 || true
	# An image can hold read-only directories; make them writable to remove
	# them, and never let the cleanup change the result.
	chmod -R u+rwX "$work" 2>/dev/null || true
	rm -rf "$work" || true
	exit "$rc"
}
trap cleanup EXIT
root=$work/root
mkdir "$root"

fail=0
bad() {
	echo "FAIL: $*" >&2
	fail=1
}

# The policy: fingerprints, and the PEM lines used to find a certificate in
# a binary.
declare -A listed=()
: >"$work/probes"
while read -r fp kind file _; do
	case $fp in '' | '#'*) continue ;; esac
	got=$(openssl x509 -in "$CERTS/$file" -outform der | sha256sum | cut -c1-64)
	[ "$got" = "$fp" ] || { echo "image.sh: $file has sha256 $got, the list says $fp" >&2; exit 2; }
	listed[$fp]="$kind $file"
	n=$(sed '/^-----/d' "$CERTS/$file" | wc -l)
	sed '/^-----/d' "$CERTS/$file" | sed -n "4p;$(((n + 1) / 2))p" >>"$work/probes"
done <"$LIST"
echo "policy: ${#listed[@]} listed certificate(s)"

# Export the file system. tar skips device files it cannot create.
cid=$(docker create ${platform:+--platform "$platform"} "$IMAGE" /nonexistent)
# A failed export must not pass as a clean image: any tar error fails.
if ! docker export "$cid" | tar -x -C "$root" --no-same-owner --no-same-permissions --exclude='dev/*' 2>"$work/tar.err"; then
	echo "image.sh: could not export $IMAGE:" >&2
	head -20 "$work/tar.err" >&2
	exit 2
fi
[ -d "$root/etc" ] || [ -d "$root/usr" ] || { echo "image.sh: $IMAGE has no /etc or /usr" >&2; exit 2; }
# A host that is not root cannot read a file the image keeps mode 000
# (/etc/shadow): make every file readable, so no file is skipped.
chmod -R u+rwX "$root"

allowed() {
	local p
	for p in "${allow[@]}"; do
		# shellcheck disable=SC2053 # a glob match is the point
		[[ $1 == $p ]] && return 0
	done
	return 1
}

# Every regular file with a PEM certificate or a probe line. Links are left
# out: they point at a path in the image, which is scanned as itself.
# A grep error (an unreadable file) fails the check: exit 1 only means no
# match.
find "$root" -type f -print0 >"$work/all-files"
rc=0
xargs -0 grep -laF -e '-----BEGIN CERTIFICATE-----' -e '-----BEGIN TRUSTED CERTIFICATE-----' -f "$work/probes" <"$work/all-files" >"$work/files.unsorted" 2>"$work/grep.err" || rc=$?
# xargs exits 123 when a grep finds nothing, so a grep error shows only on
# stderr.
if [ -s "$work/grep.err" ] || { [ "$rc" -gt 1 ] && [ "$rc" -ne 123 ]; }; then
	echo "image.sh: grep failed ($rc) while scanning $IMAGE:" >&2
	head -20 "$work/grep.err" >&2
	exit 2
fi
sort "$work/files.unsorted" >"$work/files"

# Every listed certificate is offered as an untrusted intermediate, so an
# intermediate whose issuer is listed too still finds its path.
cat "$CERTS"/*.pem >"$work/all.pem"

# The verify test uses only the bundle given (-no-CApath, and -no-CAstore
# in OpenSSL 3), or a root the host trusts would be blamed on the image. A
# listed root must verify against itself, or the test is broken.
certs=()
while read -r fp kind file _; do
	case $fp in '' | '#'*) continue ;; esac
	certs+=("$CERTS/$file")
	[ -n "${control:-}" ] || [ "$kind" != root ] || control=$CERTS/$file
done <"$LIST"
verify_flags=()
for flags in "-no-CApath -no-CAstore" "-no-CApath"; do
	read -r -a try <<<"$flags"
	if openssl verify "${try[@]}" -CAfile "$control" "$control" >/dev/null 2>&1; then
		verify_flags=("${try[@]}")
		break
	fi
done
[ "${#verify_flags[@]}" -gt 0 ] || { echo "image.sh: the host's openssl verify cannot verify a listed root against itself" >&2; exit 2; }

files=0
bundles=0
binaries=0
while IFS= read -r f; do
	path=${f#"$root"}
	allowed "$path" && { echo "allowed: $path"; continue; }
	# p11-kit sources are input to update-ca-trust, not trust stores: a
	# blocklist entry beside them overrides them, and the extracted stores
	# below are what clients read.
	case $path in /usr/share/pki/ca-trust-source/* | /etc/pki/ca-trust/source/*) continue ;; esac
	# A binary, or program source (Go module cache test data, a vendored
	# library), is reported, not failed: it is not a trust store until a
	# program is built from it. Keep this list the same as the module's.
	is_src=0
	case $path in *.go | *.c | *.h | *.cc | *.cpp | *.java | *.rs | *.js | *.mjs | *.cjs | *.ts | *.rb | *.py) is_src=1 ;; esac
	if [ "$is_src" = 1 ] || [ "$(tr -d '\000' <"$f" | wc -c)" -ne "$(wc -c <"$f")" ]; then
		if grep -qaF -f "$work/probes" "$f"; then
			binaries=$((binaries + 1))
			if [ "$strict_binaries" = 1 ]; then
				bad "$path: a binary or source file that holds a listed certificate"
			else
				echo "WARN: $path: a binary or source file that holds a listed certificate (not edited)" >&2
			fi
		fi
		continue
	fi
	files=$((files + 1))
	# Split the blocks (any line width, CRLF too) and fingerprint each one.
	dir=$(mktemp -d -p "$work")
	tr -d '\r' <"$f" | awk -v dir="$dir" '
		/^-----BEGIN (TRUSTED )?CERTIFICATE-----$/ { n++; out = sprintf("%s/%05d.pem", dir, n); inblk = 1 }
		inblk { print > out }
		/^-----END (TRUSTED )?CERTIFICATE-----$/ { inblk = 0; close(out) }'
	ncerts=0
	for pem in "$dir"/*.pem; do
		[ -e "$pem" ] || continue
		der=$(openssl x509 -in "$pem" -outform der 2>/dev/null | sha256sum | cut -c1-64) || continue
		[ "$der" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ] && continue # openssl could not read it
		ncerts=$((ncerts + 1))
		cat "$pem" >>"$dir/bundle"
		[ -n "${listed[$der]:-}" ] || continue
		if [ "$path" = "$P11_TRUST" ]; then
			# p11-kit keeps a blocked certificate in this file on purpose,
			# marked as rejected for every use.
			openssl x509 -in "$pem" -noout -text -trustout 2>/dev/null | grep -A1 '^Rejected Uses:' | grep -q 'TLS Web Server Authentication' ||
				bad "$path: holds ${listed[$der]#* } (${listed[$der]%% *}) and does not reject it"
		else
			bad "$path: holds ${listed[$der]#* } (${listed[$der]%% *})"
		fi
	done
	# A listed certificate's text outside the blocks parsed above (an
	# indented or quoted PEM, a broken BEGIN line) is still a listed
	# certificate, even in a file with other certificates.
	if tr -d '\r' <"$f" | awk '
		/^-----BEGIN (TRUSTED )?CERTIFICATE-----$/ { inblk = 1; buf = ""; next }
		inblk && /^-----END (TRUSTED )?CERTIFICATE-----$/ { inblk = 0; next }
		inblk { buf = buf $0 "\n"; next }
		{ print }
		END { if (inblk) printf "%s", buf }' | grep -qF -f "$work/probes"; then
		bad "$path: holds a listed certificate's text in a layout openssl cannot read"
	fi
	# Does a listed certificate verify against this file as a trust store?
	# P11_TRUST is left out: openssl verify ignores its rejected uses, and
	# tls-ca-bundle.pem, extracted from the same store, is verified.
	if [ "$ncerts" -gt 0 ] && [ "$path" != "$P11_TRUST" ]; then
		bundles=$((bundles + 1))
		while IFS= read -r ok; do
			bad "$path: ${ok##*/} verifies against it"
		done < <(openssl verify "${verify_flags[@]}" -CAfile "$dir/bundle" -untrusted "$work/all.pem" "${certs[@]}" 2>/dev/null | sed -n 's/: OK$//p')
	fi
	rm -rf "$dir"
done <"$work/files"
echo "scanned $files PEM file(s), $bundles verified as trust stores"

# The system bundle must not be empty.
sysb=
for b in /etc/ssl/certs/ca-certificates.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/ssl/cert.pem; do
	if [ -f "$root$b" ] && [ ! -L "$root$b" ]; then
		sysb=$b
		break
	fi
done
if [ -n "$sysb" ]; then
	c=$(grep -c '^-----BEGIN CERTIFICATE-----' "$root$sysb" || true)
	echo "$sysb: $c certificate(s)"
	[ "$c" -ge "$min_roots" ] || bad "$sysb: $c certificate(s), expected at least $min_roots"
else
	# Every TLS client needs one; an image with none either has no TLS
	# client (pass --min-roots 0) or one that uses a built-in list.
	[ "$min_roots" -eq 0 ] || bad "no system CA bundle (node:alpine and others ship none: install ca-certificates before the kit)"
fi

# Java. A JDK's own keystore (lib/security/cacerts) needs the JDK's
# blocked.certs too; a keystore that only p11-kit extracts for a JDK that
# is not in the image needs none.
jdk_keystore=0
find "$root" -type f -name cacerts -print0 2>/dev/null >"$work/keystores" || true
if [ -s "$work/keystores" ]; then
	command -v keytool >/dev/null || { echo "image.sh: the image has a Java keystore; install keytool (a JDK) on the host" >&2; exit 2; }
	while IFS= read -r -d '' ks; do
		path=${ks#"$root"}
		allowed "$path" && continue
		# A PEM file named cacerts (some distributions) is checked above.
		[ "$(tr -d '\000' <"$ks" | wc -c)" -ne "$(wc -c <"$ks")" ] || continue
		case $path in */lib/security/cacerts) jdk_keystore=1 ;; esac
		if ! out=$(keytool -list -keystore "$ks" -storepass changeit 2>&1); then
			bad "$path: keytool cannot read it: $out"
			continue
		fi
		while read -r fp; do
			fp=$(tr -d : <<<"$fp" | tr 'A-F' 'a-f')
			[ -n "${listed[$fp]:-}" ] && bad "$path: holds ${listed[$fp]#* }"
		done < <(sed -n 's/.*fingerprint (SHA-256): //p' <<<"$out")
		echo "$path: checked"
	done <"$work/keystores"
	find "$root" -type f -name blocked.certs -path '*/lib/security/*' -print0 >"$work/blocked" 2>/dev/null || true
	[ -s "$work/blocked" ] || [ "$jdk_keystore" = 0 ] || bad "a Java keystore is in the image in a JDK but no JDK blocked.certs blocks the listed certificates"
	while IFS= read -r -d '' bc; do
		for fp in "${!listed[@]}"; do
			grep -qxi "$fp" "$bc" || bad "${bc#"$root"}: does not block ${listed[$fp]#* }"
		done
		echo "${bc#"$root"}: checked"
	done <"$work/blocked"
fi

# NSS.
find "$root" -type f \( -name cert9.db -o -name cert8.db \) -print0 2>/dev/null >"$work/nss" || true
if [ -s "$work/nss" ]; then
	command -v certutil >/dev/null || { echo "image.sh: the image has an NSS database; install certutil (libnss3-tools) on the host" >&2; exit 2; }
	while IFS= read -r -d '' db; do
		d=$(dirname "$db")
		path=${d#"$root"}
		allowed "$path" && continue
		case $db in *cert9.db) spec=sql:$d ;; *) spec=dbm:$d ;; esac
		out=$(certutil -L -d "$spec" 2>&1) || { bad "$path: certutil cannot read it: $out"; continue; }
		for fp in "${!listed[@]}"; do
			file=${listed[$fp]#* }
			nick=harden-${file%.pem}
			grep -qE "^${nick}[[:space:]]+p,p,p[[:space:]]*\$" <<<"$out" || bad "$path: does not distrust $file (no '$nick' with trust p,p,p)"
		done
		echo "$path: checked"
	done <"$work/nss"
fi

# Clients with their own root list. A clean system store does nothing for a
# client that does not read it, so the image's environment must point each
# one at the store (lessons of connectorhub#262 and hyphae#71/#72).
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" >"$work/env" 2>/dev/null ||
	{ echo "image.sh: cannot read the environment of $IMAGE" >&2; exit 2; }
envval() { sed -n "s/^$1=//p" "$work/env" | tail -1; }
find "$root" -type f -perm -u+x \( -name node -o -name uv -o -name uvx -o -name chrome -o -name chromium -o -name chromium-browser -o -name headless_shell \) -print >"$work/clients"
while IFS= read -r exe; do
	path=${exe#"$root"}
	allowed "$path" && continue
	case ${exe##*/} in
	node)
		# Node trusts its built-in list (it holds the emSign roots and, in
		# some versions, AAA) unless --use-openssl-ca makes it read only
		# OpenSSL's store. An official Node binary's OpenSSL looks in its own
		# directory, not the distribution's, so it trusts nothing (and every
		# TLS call fails) unless SSL_CERT_FILE names the bundle.
		# --use-system-ca adds the system store to the built-in list, which
		# keeps the emSign roots: it does not count.
		cf=$(envval SSL_CERT_FILE)
		case " $(envval NODE_OPTIONS) " in
		*" --use-openssl-ca "*)
			if [ -n "$cf" ] && [ -f "$root$cf" ]; then
				echo "$path: NODE_OPTIONS=--use-openssl-ca, SSL_CERT_FILE=$cf"
			else
				bad "$path: --use-openssl-ca without SSL_CERT_FILE set to the system bundle: an official Node binary then trusts no root"
			fi
			;;
		*) bad "$path: Node uses its built-in root list; set ENV NODE_OPTIONS=--use-openssl-ca and SSL_CERT_FILE=<system bundle> (--use-system-ca keeps the built-in list)" ;;
		esac
		;;
	uv | uvx)
		# uv trusts its built-in list unless SSL_CERT_FILE (or native TLS)
		# is set, and uvx installs a fresh certifi when it runs, which no
		# build step can clean, so requests must read the bundle too.
		cf=$(envval SSL_CERT_FILE)
		if [ "$(envval UV_NATIVE_TLS)" != 1 ] && { [ -z "$cf" ] || [ ! -f "$root$cf" ]; }; then
			bad "$path: uv uses its built-in root list; set ENV SSL_CERT_FILE to the system bundle"
		fi
		[ -n "$(envval REQUESTS_CA_BUNDLE)" ] || bad "$path: a certifi that uv installs at run time is not hardened; set ENV REQUESTS_CA_BUNDLE (and SSL_CERT_FILE) to the system bundle"
		;;
	*)
		# Chrome trusts the Chrome Root Store built into its binary and takes
		# distrust only from an NSS database in $HOME/.pki/nssdb. The kit
		# distrusts the listed certificates in every NSS database in the
		# image; the program must copy one to $HOME/.pki/nssdb when it starts
		# (hyphae pdfserv/pdfgen/nssdb.go) and check that Chrome opens it.
		[ -s "$work/nss" ] || bad "$path: Chrome uses its built-in roots and the image has no NSS database to distrust them (ship one, made with certutil before the kit, and copy it to \$HOME/.pki/nssdb at start)"
		echo "WARN: $path: Chrome reads distrust only from \$HOME/.pki/nssdb at run time; the program must install the image's NSS database there" >&2
		;;
	esac
done <"$work/clients"

# Roots compiled into a binary as DER (Go's x509roots/fallback, Node,
# Chrome, uv): search each binary for each listed certificate's public key,
# which a cross-signed copy shares (mars#306 searched by name).
if command -v python3 >/dev/null; then
	for c in "$CERTS"/*.pem; do
		printf '%s ' "$(basename "$c")"
		openssl x509 -in "$c" -noout -pubkey | openssl pkey -pubin -outform der | od -An -v -tx1 | tr -d ' \n'
		echo
	done >"$work/spki"
	cat >"$work/der.py" <<'PY'
import sys
keys = {}
for line in open(sys.argv[1]):
    name, hexkey = line.split()
    keys.setdefault(bytes.fromhex(hexkey), []).append(name)
for path in open(sys.argv[2], "rb").read().split(b"\0"):
    if not path:
        continue
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        print("ERROR", path.decode(errors="replace"), e)
        continue
    if b"\0" not in data:
        continue
    hits = sorted({n for k, ns in keys.items() if k in data for n in ns})
    if hits:
        print(path.decode(errors="replace"), " ".join(hits))
PY
	python3 -I "$work/der.py" "$work/spki" "$work/all-files" >"$work/der-hits"
	if grep -q '^ERROR ' "$work/der-hits"; then
		grep '^ERROR ' "$work/der-hits" >&2
		echo "image.sh: could not read a file of $IMAGE" >&2
		exit 2
	fi
	while read -r f hits; do
		path=${f#"$root"}
		allowed "$path" && continue
		binaries=$((binaries + 1))
		if [ "$strict_binaries" = 1 ]; then
			bad "$path: a binary that holds the key of $hits"
		else
			echo "WARN: $path: a binary that holds the key of $hits in DER (a built-in root list: point it at the system store)" >&2
		fi
	done <"$work/der-hits"
else
	echo "WARN: no python3 on the host: binaries were not searched for DER roots" >&2
fi

if [ "$fail" -ne 0 ]; then
	echo "FAIL: $IMAGE does not hold the build-harden policy" >&2
	exit 1
fi
echo "OK: $IMAGE holds the build-harden policy ($binaries binary or source file(s) warned)"
