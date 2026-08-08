#!/bin/bash
# Build a distributable Stark.dmg for hosting on a website.
#
# Tiers, best to worst, picked automatically from what's in your keychain:
#
#   1. Developer ID + notarization  → downloads and opens with no warning.
#      Needs a paid Apple Developer account ($99/yr) and, for notarising,
#      a notarytool keychain profile:
#        xcrun notarytool store-credentials "stark-notary" \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#      Then: NOTARY_PROFILE=stark-notary ./make_release.sh
#
#   2. Developer ID, no notarization → Gatekeeper still blocks on first open.
#
#   3. Ad-hoc / self-signed → macOS refuses to open it normally. Users must
#      right-click → Open, or run:  xattr -dr com.apple.quarantine /Applications/Stark.app
#      Fine for a "for developers" link; not fine for a general audience.
#
# NOTE: this packages the APP ONLY. See DISTRIBUTION.md — the app still needs a
# Python with mlx-lm and an 850 MB model on the user's machine, so this DMG is
# not yet a working download for a non-technical user.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
APP="build/Stark.app"
DMG="build/Stark-$VERSION.dmg"
STAGE="build/dmg"

./make_app.sh >/dev/null
echo "Built $APP"

# --- sign -------------------------------------------------------------------
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
         | grep "Developer ID Application" | head -1 \
         | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$DEVID" ]; then
    echo "Signing with: $DEVID"
    # Hardened runtime is required for notarization.
    codesign --force --deep --options runtime --timestamp \
             -s "$DEVID" "$APP"
    SIGNED_PROPERLY=1
else
    echo "⚠️  No 'Developer ID Application' certificate found."
    echo "    Falling back to the local signature; users will hit Gatekeeper."
    SIGNED_PROPERLY=0
fi

# --- package ----------------------------------------------------------------
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install affordance

hdiutil create -volname "Stark" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Packaged $DMG"

# --- notarize ---------------------------------------------------------------
if [ "$SIGNED_PROPERLY" = "1" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Submitting to Apple for notarization (this takes a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "✓ Notarized and stapled. $DMG is ready to host."
elif [ "$SIGNED_PROPERLY" = "1" ]; then
    echo "Signed but NOT notarized (set NOTARY_PROFILE to notarize)."
    echo "Users will still see a Gatekeeper warning on first open."
else
    echo ""
    echo "$DMG is hostable, but tell users to run this after dragging it in:"
    echo "  xattr -dr com.apple.quarantine /Applications/Stark.app"
fi
