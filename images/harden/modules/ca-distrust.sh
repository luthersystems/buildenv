#!/bin/sh
# ca-distrust: make the image trust no CA listed in policy/ca-distrust.list.
#
# Why: when a CA's key leaks (CVE-2026-111943, eMudhra), every TLS client in
# the image must refuse a chain through it. Clients read different stores, so
# each store is handled:
#
#   - Debian, Ubuntu and Alpine: a listed root is removed from
#     /usr/share/ca-certificates (and deselected in /etc/ca-certificates.conf,
#     so a plain update-ca-certificates run does not add it back) and from
#     /usr/local/share/ca-certificates, then the system bundle is rebuilt.
#   - Red Hat and Amazon Linux: every listed certificate goes into the p11-kit
#     blocklist, which marks it distrusted for OpenSSL and GnuTLS, roots and
#     intermediates alike.
#   - Every other PEM file in the image (the system bundle when it is only
#     prebuilt, Python certifi and pip, botocore, the AWS CLI, google-cloud-cli
#     and any later tool's bundle) loses each listed certificate, found by its
#     content, whatever the file's name or line width.
#   - Java: a listed root is deleted from each cacerts keystore, and every
#     listed certificate goes into each JDK's lib/security/blocked.certs, which
#     the JDK checks for every certificate of a chain.
#   - NSS (Chrome, Firefox): every listed certificate is added to each NSS
#     database with trust "p,p,p" (explicitly distrusted).
#
# A trust store holds roots, so removing a leaked intermediate from it does
# nothing: the intermediate is blocked by the block lists above, and every
# copy of it is listed (eMudhra's intermediates are also cross-signed by
# Sectigo's AAA Certificate Services), so a chain through another root is
# refused too. Clients with no block list (curl and git on Debian and Alpine)
# are protected by the roots' removal and by the image check, which fails
# when a listed certificate still verifies against any trust store.
#
# The module checks its result and fails the build if a listed certificate is
# still trusted. A binary file (one with a NUL byte, such as a Node.js binary
# with its CA list compiled in) cannot be edited; one that holds a listed
# certificate is reported, and fails the build when HARDEN_STRICT_BINARIES=1.
# HARDEN_NSSDB (optional) lists more NSS database directories.
set -eu

HARDEN_DIR=${HARDEN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
LIST=$HARDEN_DIR/policy/ca-distrust.list
CERTS=$HARDEN_DIR/policy/ca-distrust
CONF=/etc/ca-certificates.conf
PKI=/etc/pki/ca-trust

log() { echo "harden/ca-distrust: $*"; }
die() {
	echo "harden/ca-distrust: $*" >&2
	exit 1
}

for tool in awk grep sed find base64 sha256sum mktemp; do
	command -v "$tool" >/dev/null 2>&1 ||
		die "the image has no $tool; install it before this step (findutils, coreutils, grep, sed or gawk)"
done
[ -f "$LIST" ] || die "no policy list at $LIST"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Load the policy. For each certificate, check its PEM against its listed
# fingerprint, then record:
#   bodies: "<base64 body> <kind> <fingerprint> <pem file>"
#   probes: two of its 64-column PEM lines, to find it in a file that holds
#           it in another layout (not a PEM block) or in a binary
#   fps:    its fingerprint, upper case hex (Java's blocked.certs form)
: >"$work/bodies"
: >"$work/probes"
: >"$work/fps"
n=0
while read -r fp kind file _; do
	case $fp in '' | '#'*) continue ;; esac
	case $kind in root | intermediate) ;; *) die "$LIST: $fp: kind must be root or intermediate, not $kind" ;; esac
	pem=$CERTS/$file
	[ -f "$pem" ] || die "$LIST: no file $pem"
	body=$(sed -n '/^-----BEGIN CERTIFICATE-----/,/^-----END CERTIFICATE-----/p' "$pem" | sed '/^-----/d' | tr -d ' \t\r\n')
	got=$(printf '%s' "$body" | base64 -d | sha256sum | cut -c1-64)
	[ "$got" = "$fp" ] || die "$pem has sha256 $got, but the list says $fp"
	echo "$body $kind $fp $file" >>"$work/bodies"
	lines=$(sed '/^-----/d' "$pem" | wc -l)
	sed '/^-----/d' "$pem" | sed -n "4p;$(((lines + 1) / 2))p" >>"$work/probes"
	echo "$fp" | tr 'a-f' 'A-F' >>"$work/fps"
	n=$((n + 1))
done <"$LIST"
[ "$n" -gt 0 ] || die "$LIST lists no certificate"
log "policy: $n certificate(s)"

# match MODE FILE: read the PEM blocks of FILE (CERTIFICATE or TRUSTED
# CERTIFICATE, any line width, CRLF too; a block with no END line is left
# as text, and step 6 still finds a listed certificate in it). A block matches a listed
# certificate when its base64 body equals the listed body, or starts with it
# up to its last 4 characters: a TRUSTED CERTIFICATE body is the DER with
# trust settings after it, and the last base64 group can hold bytes of both.
#   strip:  print FILE without the matching blocks
#   count:  print "<blocks> <matching blocks>"
match() {
	awk -v mode="$1" -v bodies="$work/bodies" '
		BEGIN {
			while ((getline line < bodies) > 0) { split(line, f, " "); bad[f[1]] = 1; nb++; key[nb] = substr(f[1], 1, length(f[1]) - 4) }
		}
		function listed(b,    i) {
			if (b in bad) return 1
			for (i = 1; i <= nb; i++) if (substr(b, 1, length(key[i])) == key[i]) return 1
			return 0
		}
		# A block that never ends (PEM text quoted in source code, a test
		# fixture) is not a certificate: keep its lines as they are.
		function flush() { if (inblk && mode == "strip") printf "%s", blk; inblk = 0 }
		{ line = $0; sub(/\r$/, "", line) }
		line ~ /^-----BEGIN (TRUSTED )?CERTIFICATE-----$/ { flush(); inblk = 1; blk = $0 "\n"; body = ""; next }
		inblk {
			blk = blk $0 "\n"
			if (line ~ /^-----END (TRUSTED )?CERTIFICATE-----$/) {
				inblk = 0; blocks++
				if (listed(body)) matched++; else if (mode == "strip") printf "%s", blk
			} else { gsub(/[ \t]/, "", line); body = body line }
			next
		}
		mode == "strip" { print }
		END {
			flush()
			if (mode == "count") print blocks + 0, matched + 0
		}
	' "$2"
}

# count FILE: set total to the number of certificate blocks in FILE and
# listed to the number of listed ones. A malformed file fails the build.
count() {
	counts=$(match count "$1") || die "cannot read the certificates in $1"
	total=${counts% *}
	listed=${counts#* }
}

# strip FILE: remove the listed certificates from FILE in place (other lines,
# comments included, are kept). Sets listed to the number removed.
strip() {
	count "$1"
	if [ "$listed" -gt 0 ]; then
		match strip "$1" >"$work/strip" || die "cannot edit $1"
		cat "$work/strip" >"$1"
	fi
}

is_binary() {
	[ "$(tr -d '\000' <"$1" | wc -c)" -ne "$(wc -c <"$1")" ]
}

# Program source (a Go module cache's test data, x509roots, a vendored
# library) is reported like a binary, never edited: editing it breaks a
# module checksum, and it is not a trust store until a program is built
# from it, which the image check of that program's image covers.
is_source() {
	case $1 in
	*.go | *.c | *.h | *.cc | *.cpp | *.java | *.rs | *.js | *.mjs | *.cjs | *.ts | *.rb | *.py) return 0 ;;
	esac
	return 1
}

# 1. CA sources of update-ca-certificates (Debian, Ubuntu, Alpine). A file
# that holds only listed certificates is removed and deselected; a mixed one
# is stripped.
changed=0
sources=0
for dir in /usr/share/ca-certificates /usr/local/share/ca-certificates; do
	[ -d "$dir" ] || continue
	find "$dir" -xdev -type f >/dev/null # a walk that fails must fail the build
	find "$dir" -xdev -type f -name '*.crt' >"$work/src"
	while IFS= read -r crt; do
		count "$crt"
		[ "$listed" -gt 0 ] || continue
		if [ "$listed" -eq "$total" ]; then
			log "removing $crt"
			rm -f "$crt"
			if [ "$dir" = /usr/share/ca-certificates ] && [ -f "$CONF" ]; then
				name=${crt#/usr/share/ca-certificates/}
				sed -i "\\#^!\\{0,1\\}${name}\$#d" "$CONF"
				echo "!${name}" >>"$CONF"
			fi
		else
			log "removing $listed listed certificate(s) from $crt"
			strip "$crt"
		fi
		sources=$((sources + listed))
		changed=1
	done <"$work/src"
done
if [ "$changed" -eq 1 ] && command -v update-ca-certificates >/dev/null 2>&1; then
	update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates
fi

# 2. The p11-kit store (Red Hat, Amazon Linux). Block every listed
# certificate, roots and intermediates. extracted/openssl/ca-bundle.trust.crt
# keeps each blocked certificate on purpose, marked as rejected, so OpenSSL
# refuses a chain through it; the scan below skips that file.
blocked=0
if [ -d "$PKI/source" ]; then
	# Older p11-kit names the directory "blacklist".
	blocklist=$PKI/source/blocklist
	[ -d "$blocklist" ] || blocklist=$PKI/source/blacklist
	[ -d "$blocklist" ] || die "$PKI has no source/blocklist directory"
	command -v update-ca-trust >/dev/null 2>&1 || die "$PKI exists but the image has no update-ca-trust"
	while read -r _ _ _ file; do
		cp "$CERTS/$file" "$blocklist/harden-$file"
		blocked=$((blocked + 1))
	done <"$work/bodies"
	update-ca-trust extract
fi

# 3. Every other file that holds a PEM certificate, anywhere on the image's
# root file system (the image check scans all of it too). The prefilter needs a
# BEGIN line or a probe line, so a certificate in another layout is found too
# (and fails the check in step 6). Kit files, the p11-kit sources (a
# .p11-kit file is not plain PEM, and the blocklist above already covers
# them) and its trust-marked bundle are left alone.
scan() {
	find / -xdev \( -path /proc -o -path /sys -o -path /dev \) -prune -o -type f -print >/dev/null # a walk that fails must fail the build
	find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path "$HARDEN_DIR" -o -path "$work" \) -prune -o -type f \
		! -path "$PKI/source/*" \
		! -path '/usr/share/pki/ca-trust-source/*' \
		! -path "$PKI/extracted/openssl/ca-bundle.trust.crt" \
		-exec grep -laF -e '-----BEGIN CERTIFICATE-----' -e '-----BEGIN TRUSTED CERTIFICATE-----' -f "$work/probes" {} + >"$work/found" || true
}
scan
stripped=0
binaries=0
: >"$work/binaries"
while IFS= read -r f; do
	if is_binary "$f" || is_source "$f"; then
		if grep -qaF -f "$work/probes" "$f"; then
			echo "$f" >>"$work/binaries"
			binaries=$((binaries + 1))
		fi
		continue
	fi
	strip "$f"
	if [ "$listed" -gt 0 ]; then
		log "removed $listed listed certificate(s) from $f"
		stripped=$((stripped + listed))
	fi
done <"$work/found"

# 4. Java. Delete each listed root from every cacerts keystore (the JDK's own,
# Debian's ca-certificates-java store, Red Hat's extracted one is rebuilt in
# step 2), then block every listed certificate in each JDK's blocked.certs.
# Any keytool failure fails the build: an unreadable keystore must not pass
# as clean.
keytool=$(command -v keytool 2>/dev/null || true)
if [ -z "$keytool" ] && [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/keytool" ]; then
	keytool=$JAVA_HOME/bin/keytool
fi
# keystore_fps KS: print "<FINGERPRINT> <alias>" for each entry of KS.
keystore_fps() {
	if ! out=$("$keytool" -list -keystore "$1" -storepass changeit 2>&1); then
		die "keytool cannot read $1: $out"
	fi
	echo "$out" | awk '
		/trustedCertEntry|PrivateKeyEntry/ { a = $0; sub(/, [A-Z][a-z][a-z] [0-9]+, [0-9]+, (trustedCertEntry|PrivateKeyEntry).*/, "", a); next }
		/fingerprint \(SHA-256\)/ { fp = $NF; gsub(/:/, "", fp); if (a != "") print fp, a; a = "" }'
}
aliases=0
find / -xdev \( -path /proc -o -path /sys \) -prune -o -type f -name cacerts -print 2>/dev/null >"$work/keystores" || true
# A text file named cacerts is a PEM bundle, which step 3 handled. p11-kit
# writes its Java keystore from the blocklisted sources in step 2, so an
# image without a JDK (Amazon Linux) needs no keytool for it.
: >"$work/keystores.java"
while IFS= read -r ks; do
	is_binary "$ks" || continue
	case $ks in "$PKI"/extracted/*) [ -n "$keytool" ] || continue ;; esac
	echo "$ks" >>"$work/keystores.java"
done <"$work/keystores"
mv "$work/keystores.java" "$work/keystores"
while IFS= read -r ks; do
	[ -n "$keytool" ] || die "found keystore $ks but no keytool"
	keystore_fps "$ks" >"$work/ks"
	while read -r fp alias; do
		grep -qxF "$fp" "$work/fps" || continue
		log "removing '$alias' from $ks"
		out=$("$keytool" -delete -alias "$alias" -keystore "$ks" -storepass changeit -noprompt 2>&1) ||
			die "keytool cannot delete '$alias' from $ks: $out"
		aliases=$((aliases + 1))
	done <"$work/ks"
done <"$work/keystores"
jdks=0
# Debian and Ubuntu JDK packages ship lib/security/blocked.certs as a link
# to /etc/java-*-openjdk/security/blocked.certs, so find links too and edit
# each target once (luthersystems/buildenv#166).
find / -xdev \( -path /proc -o -path /sys \) -prune -o \( -type f -o -type l \) -name blocked.certs -path '*/lib/security/*' -print 2>/dev/null >"$work/found" || true
: >"$work/blocked"
while IFS= read -r bc; do
	target=$(readlink -f "$bc") && [ -f "$target" ] || die "$bc is a link to no file"
	echo "$target" >>"$work/blocked"
done <"$work/found"
sort -u "$work/blocked" -o "$work/blocked"
while IFS= read -r bc; do
	head -1 "$bc" | grep -qx 'Algorithm=SHA-256' || die "$bc does not start with Algorithm=SHA-256"
	while IFS= read -r fp; do
		grep -qxF "$fp" "$bc" || echo "$fp" >>"$bc"
	done <"$work/fps"
	jdks=$((jdks + 1))
done <"$work/blocked"
if [ -s "$work/keystores" ] && [ "$jdks" -eq 0 ]; then
	log "warning: a cacerts keystore exists but no JDK blocked.certs was found; listed intermediates are not blocked for Java"
fi

# 5. NSS databases, wherever they are (and HARDEN_NSSDB): mark every listed
# certificate as explicitly distrusted.
nssdbs=0
find / -xdev \( -path /proc -o -path /sys -o -path /dev \) -prune -o -type f \( -name cert9.db -o -name cert8.db \) -print 2>/dev/null |
	sed 's|/[^/]*$||' >"$work/nssdirs" || true
for d in ${HARDEN_NSSDB:-}; do echo "$d" >>"$work/nssdirs"; done
sort -u "$work/nssdirs" -o "$work/nssdirs"
while IFS= read -r d; do
	if [ -f "$d/cert9.db" ]; then
		db=sql:$d
	elif [ -f "$d/cert8.db" ]; then
		db=dbm:$d
	else
		continue
	fi
	command -v certutil >/dev/null 2>&1 || die "found NSS database $d but no certutil"
	while read -r _ _ _ file; do
		out=$(certutil -A -d "$db" -n "harden-${file%.pem}" -t p,p,p -i "$CERTS/$file" 2>&1) ||
			die "certutil cannot distrust $file in $d: $out"
	done <"$work/bodies"
	nssdbs=$((nssdbs + 1))
done <"$work/nssdirs"

# 6. Check the result.
openssl=$(command -v openssl 2>/dev/null || true)
: >"$work/all.pem"
while read -r _ _ _ file; do cat "$CERTS/$file" >>"$work/all.pem"; done <"$work/bodies"
# verified FILE: the listed certificates that verify with FILE as the only
# trust store, one openssl call for all of them. The default store (CApath,
# and CAstore in OpenSSL 3) is turned off, or a root the image still trusts
# elsewhere would be blamed on FILE. verify_flags is chosen by a positive
# control: a listed root must verify against itself, or the test is broken.
verified() {
	# shellcheck disable=SC2086 # verify_flags and certs are word lists
	"$openssl" verify $verify_flags -CAfile "$1" -untrusted "$work/all.pem" $certs 2>/dev/null |
		sed -n 's|^.*/\([^/]*\.pem\): OK$|\1|p' | tr '\n' ' ' | sed 's/ $//'
}
certs=
while read -r _ _ _ file; do certs="$certs $CERTS/$file"; done <"$work/bodies"
if [ -n "$openssl" ]; then
	control=$CERTS/$(awk '$2 == "root" { print $4; exit }' "$work/bodies")
	verify_flags=
	for flags in "-no-CApath -no-CAstore" "-no-CApath"; do
		# shellcheck disable=SC2086 # flags is a word list
		if "$openssl" verify $flags -CAfile "$control" "$control" >/dev/null 2>&1; then
			verify_flags=$flags
			break
		fi
	done
	[ -n "$verify_flags" ] || die "openssl verify cannot verify a listed root against itself ($openssl); fix or remove openssl before this step"
fi
scan
while IFS= read -r f; do
	{ is_binary "$f" || is_source "$f"; } && continue
	count "$f"
	[ "$listed" -eq 0 ] || die "a listed certificate is still in $f"
	if grep -qF -f "$work/probes" "$f"; then
		die "$f holds a listed certificate in a layout this module cannot edit"
	fi
	# A listed intermediate must not chain to a root this file still trusts
	# (eMudhra's are cross-signed by AAA Certificate Services, which an old
	# certifi still holds). Only an image with openssl can test it here; the
	# image check always does.
	if [ "$total" -gt 0 ] && [ -n "$openssl" ]; then
		ok=$(verified "$f")
		[ -z "$ok" ] || die "$ok still verifies against $f: remove the root that issued it from that file, or upgrade the package that ships it"
	fi
done <"$work/found"
while IFS= read -r ks; do
	keystore_fps "$ks" >"$work/ks"
	while read -r fp alias; do
		grep -qxF "$fp" "$work/fps" && die "'$alias' is still in $ks"
	done <"$work/ks"
done <"$work/keystores"
if [ -d "$PKI/extracted/pem" ]; then
	for pem in "$PKI"/extracted/pem/*.pem; do
		[ -f "$pem" ] || continue
		count "$pem"
		[ "$listed" -eq 0 ] || die "a listed certificate is still in $pem"
	done
fi

while IFS= read -r f; do
	log "warning: $f (a binary or program source) holds a listed certificate and is not edited"
done <"$work/binaries"
if [ "$binaries" -gt 0 ] && [ "${HARDEN_STRICT_BINARIES:-}" = 1 ]; then
	die "$binaries binary or source file(s) hold a listed certificate (HARDEN_STRICT_BINARIES=1)"
fi

log "removed $sources source certificate(s), blocked $blocked in p11-kit, stripped $stripped from bundles, removed $aliases keystore alias(es), blocked $n in $jdks JDK(s) and $nssdbs NSS database(s); $binaries binary or source file(s) reported"
