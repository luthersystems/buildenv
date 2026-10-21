#!/bin/sh
# Remove the eMudhra (emSign) root CAs from the image's trust stores.
#
# In October 2026 the private keys of eight eMudhra intermediate CAs
# (EM DV/OV/EV TLS CA - G3B and G3C, EM OV CS CA - G3B and G3C) were
# compromised (CVE-2026-111943, golang/go#82345). Go 1.26.10 refuses them
# in crypto/x509, and Mozilla removed emSign ECC Root CA - G3 from NSS, but
# the distribution ca-certificates packages in our base images still trust
# all four emSign roots. Most tools in an image (curl, git, openssl, Java,
# Python without certifi) read those stores, so this script removes every emSign root
# from them:
#
#   - the system bundle (/etc/ssl/certs), on Alpine, Debian and Ubuntu,
#     also when the image has only a prebuilt bundle;
#   - the JDK cacerts and the Debian Java keystore (Temurin images).
#
# It fails the build if an emSign root is still present afterwards. Run it as
# root, as the last step that installs or upgrades packages: a later
# `apk upgrade` or `apt-get upgrade` of ca-certificates restores the files
# (the deselect lines in /etc/ca-certificates.conf keep a plain
# update-ca-certificates run from adding them back).
set -eu

MOZILLA_DIR=/usr/share/ca-certificates/mozilla
CONF=/etc/ca-certificates.conf
BUNDLE=/etc/ssl/certs/ca-certificates.crt

# Line 4 of each emSign root's PEM file (in Mozilla's set as of 2026-10),
# used to find the root in a bundle whatever the bundle's layout.
EMSIGN_LINES="
IDAeBgNVBAMTF2VtU2lnbiBFQ0MgUm9vdCBDQSAtIEMzMB4XDTE4MDIxODE4MzAw
bm9sb2dpZXMgTGltaXRlZDEgMB4GA1UEAxMXZW1TaWduIEVDQyBSb290IENBIC0g
SW5jMRwwGgYDVQQDExNlbVNpZ24gUm9vdCBDQSAtIEMxMB4XDTE4MDIxODE4MzAw
ZWNobm9sb2dpZXMgTGltaXRlZDEcMBoGA1UEAxMTZW1TaWduIFJvb3QgQ0EgLSBH
"

found=0
if [ -d "$MOZILLA_DIR" ]; then
	for crt in "$MOZILLA_DIR"/emSign_*.crt; do
		[ -e "$crt" ] || continue
		found=$((found + 1))
		name=${crt#/usr/share/ca-certificates/}
		echo "distrust-emudhra: removing $name"
		rm -f "$crt"
		if [ -f "$CONF" ]; then
			sed -i "\\#^${name}\$#d; \\#^!${name}\$#d" "$CONF"
			echo "!${name}" >>"$CONF"
		fi
	done
fi

if [ "$found" -gt 0 ]; then
	update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates
fi

# Remove any emSign PEM block that is still in the bundle. This covers an
# image with only a prebuilt bundle and no per-root files (Alpine with only
# ca-certificates-bundle), where update-ca-certificates has nothing to drop.
if [ -f "$BUNDLE" ]; then
	tmp=$(mktemp)
	awk -v lines="$EMSIGN_LINES" '
		BEGIN { n = split(lines, want, "\n"); for (i = 1; i <= n; i++) if (want[i] != "") bad[want[i]] = 1 }
		/^-----BEGIN CERTIFICATE-----/ { inblk = 1; blk = $0 "\n"; drop = 0; next }
		inblk { blk = blk $0 "\n"; if ($0 in bad) drop = 1
			if (/^-----END CERTIFICATE-----/) { inblk = 0; if (drop) removed++; else printf "%s", blk }
			next }
		{ print }
		END { if (removed) printf "distrust-emudhra: removed %d emSign block(s) from the bundle\n", removed > "/dev/stderr" }
	' "$BUNDLE" >"$tmp"
	cat "$tmp" >"$BUNDLE"
	rm -f "$tmp"
fi

# Check the system bundle and the hashed links.
for line in $EMSIGN_LINES; do
	if [ -f "$BUNDLE" ] && grep -qF "$line" "$BUNDLE"; then
		echo "distrust-emudhra: an emSign root is still in $BUNDLE" >&2
		exit 1
	fi
done
if ls /etc/ssl/certs 2>/dev/null | grep -qi 'emsign'; then
	echo "distrust-emudhra: /etc/ssl/certs still has an emSign entry" >&2
	exit 1
fi

# Java keystores: the JDK's own cacerts (Temurin: $JAVA_HOME/lib/security)
# and the Debian ca-certificates-java store. A Temurin alias holds commas
# (cn_emsign_root_ca__g1,o_emudhra_inc,...), so the alias is everything
# before the ", <date>, trustedCertEntry" tail. Any keytool failure fails
# the build: an unreadable keystore must not pass as clean.
aliases=0
list=$(mktemp)
for ks in "${JAVA_HOME:-/nonexistent}/lib/security/cacerts" \
	/etc/ssl/certs/java/cacerts \
	/usr/lib/jvm/*/lib/security/cacerts \
	/opt/java/*/lib/security/cacerts; do
	[ -f "$ks" ] || continue
	# The same file can appear twice (JAVA_HOME is one of the globs).
	real=$(readlink -f "$ks")
	grep -qxF "$real" "$list" 2>/dev/null && continue
	echo "$real" >>"$list"
done
while IFS= read -r ks; do
	keytool=$(command -v keytool 2>/dev/null || true)
	if [ -z "$keytool" ] && [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/keytool" ]; then
		keytool=$JAVA_HOME/bin/keytool
	fi
	if [ -z "$keytool" ]; then
		echo "distrust-emudhra: found $ks but no keytool" >&2
		exit 1
	fi
	if ! out=$("$keytool" -list -keystore "$ks" -storepass changeit 2>&1); then
		echo "distrust-emudhra: keytool cannot read $ks: $out" >&2
		exit 1
	fi
	echo "$out" |
		sed -n 's/^\(.*\), [A-Z][a-z][a-z] [0-9]*, [0-9]*, trustedCertEntry.*/\1/p' |
		grep -iE 'emsign|emudhra' >"$list.aliases" || true
	while IFS= read -r alias; do
		echo "distrust-emudhra: removing alias '$alias' from $ks"
		"$keytool" -delete -alias "$alias" -keystore "$ks" -storepass changeit -noprompt 2>/dev/null
		aliases=$((aliases + 1))
	done <"$list.aliases"
	if ! out=$("$keytool" -list -v -keystore "$ks" -storepass changeit 2>&1); then
		echo "distrust-emudhra: keytool cannot read $ks: $out" >&2
		exit 1
	fi
	if echo "$out" | grep -qiE '^(Owner|Issuer):.*(emSign|eMudhra)'; then
		echo "distrust-emudhra: an emSign root is still in $ks" >&2
		exit 1
	fi
done <"$list"
rm -f "$list" "$list.aliases"

echo "distrust-emudhra: removed $found emSign root file(s) and $aliases keystore alias(es)"
