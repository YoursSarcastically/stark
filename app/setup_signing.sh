#!/bin/bash
# One-time setup: create a self-signed code-signing certificate named "Stark Dev"
# in your login keychain.
#
# Why: make_app.sh ad-hoc signs (`codesign -s -`), and an ad-hoc signature's identity
# is its cdhash — which changes on every build. macOS TCC keys the Accessibility
# grant to that identity, so every rebuild silently revokes the permission and you
# have to re-toggle Stark in System Settings. Signing with a STABLE identity makes
# the grant stick across rebuilds.
#
# Run this once, do the manual trust step it prints, then rebuild with ./make_app.sh.
set -euo pipefail

IDENTITY="Stark Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ Code-signing identity \"$IDENTITY\" already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Generating self-signed code-signing certificate \"$IDENTITY\"…"
openssl req -x509 -newkey rsa:2048 -days 3650 \
    -keyout "$TMP/dev.key" -out "$TMP/dev.crt" -nodes \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

openssl pkcs12 -export \
    -in "$TMP/dev.crt" -inkey "$TMP/dev.key" \
    -out "$TMP/dev.p12" -password pass:stark >/dev/null 2>&1

security import "$TMP/dev.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P stark -T /usr/bin/codesign

echo ""
echo "✓ Certificate imported into your login keychain."
echo ""
echo "ONE MANUAL STEP (required before codesign will use it):"
echo "  1. Open Keychain Access → login → Certificates."
echo "  2. Double-click \"$IDENTITY\"."
echo "  3. Expand ▸ Trust, set \"Code Signing\" to \"Always Trust\", close (enter password)."
echo ""
echo "Then: ./make_app.sh   (it picks up \"$IDENTITY\" automatically)"
echo "Re-grant Accessibility ONCE after the next build; it will stick from then on."
