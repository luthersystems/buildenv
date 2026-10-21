#!/bin/sh
# Remove the eMudhra (emSign) root CAs from the image's trust stores.
#
# In October 2026 the private keys of eight eMudhra intermediate CAs
# (EM DV/OV/EV TLS CA - G3B and G3C, EM OV CS CA - G3B and G3C) were
# compromised (CVE-2026-111943, golang/go#82345). Go 1.26.10 refuses them
# in crypto/x509, and Mozilla removed emSign ECC Root CA - G3 from NSS, but
# the distribution ca-certificates packages in our base images still trust
# all four emSign roots. Every other tool in an image (curl, git, openssl,
# Python, Java) reads those stores, so this script removes every emSign root
# from them:
#
#   - the system bundle (/etc/ssl/certs), on Alpine, Debian and Ubuntu;
#   - each Java cacerts keystore it finds (Temurin images).
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

# Check the system bundle, also when no emSign file was found above (an
# image with only a prebuilt bundle).
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

# Java keystores. Temurin ships its own cacerts; the Debian
# ca-certificates-java hook keeps /etc/ssl/certs/java/cacerts. A Temurin
# alias holds commas (cn_emsign_root_ca__g1,o_emudhra_inc,...), so the alias
# is everything before the ", <date>, trustedCertEntry" tail.
keystores=$(find / -xdev -name cacerts -type f 2>/dev/null || true)
if [ -n "$keystores" ]; then
	keytool=$(command -v keytool 2>/dev/null || true)
	if [ -z "$keytool" ] && [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/keytool" ]; then
		keytool=$JAVA_HOME/bin/keytool
	fi
	if [ -z "$keytool" ]; then
		echo "distrust-emudhra: found a cacerts keystore but no keytool" >&2
		exit 1
	fi
	for ks in $keystores; do
		"$keytool" -list -keystore "$ks" -storepass changeit 2>/dev/null |
			sed -n 's/^\(.*\), [A-Z][a-z][a-z] [0-9]*, [0-9]*, trustedCertEntry.*/\1/p' |
			grep -iE 'emsign|emudhra' >/tmp/distrust-emudhra.aliases || true
		while IFS= read -r alias; do
			echo "distrust-emudhra: removing alias '$alias' from $ks"
			"$keytool" -delete -alias "$alias" -keystore "$ks" -storepass changeit -noprompt
		done </tmp/distrust-emudhra.aliases
		rm -f /tmp/distrust-emudhra.aliases
		if "$keytool" -list -v -keystore "$ks" -storepass changeit 2>/dev/null |
			grep -qiE '^(Owner|Issuer):.*(emSign|eMudhra)'; then
			echo "distrust-emudhra: an emSign root is still in $ks" >&2
			exit 1
		fi
	done
fi

echo "distrust-emudhra: removed $found emSign root file(s)"
