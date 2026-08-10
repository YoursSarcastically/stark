#!/bin/bash
# Build Stark.app (release) into app/build/. Run once, then open build/Stark.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Stark.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stark "$APP/Contents/MacOS/Stark"

# The inference engine. Binary and dylibs must land in one directory: the
# binary's LC_RPATH is @loader_path, so they resolve each other by proximity.
# Without this the app is useless on any machine but the one that built it.
ENGINE="../vendor/llama-b10333"
if [ -x "$ENGINE/llama-server" ]; then
  mkdir -p "$APP/Contents/Resources/llama"
  cp "$ENGINE/llama-server" "$APP/Contents/Resources/llama/"
  cp "$ENGINE"/*.dylib "$APP/Contents/Resources/llama/" 2>/dev/null || true
  echo "  bundled llama-server ($(du -sh "$APP/Contents/Resources/llama" | cut -f1))"
else
  echo "  ⚠️  vendor/llama-b10333/llama-server missing — the app will not run."
  echo "     Fetch it: see vendor/README.md"
fi

# The weights. Bundling them makes the .app self-contained: no first-run
# download, no network, nothing for the user to configure. Set STARK_MODEL to
# build a smaller app that expects a model path in ~/.stark/config.json.
MODEL="${STARK_MODEL:-../model/stark-1.7b-Q5_K_M.gguf}"
if [ -f "$MODEL" ]; then
  mkdir -p "$APP/Contents/Resources/model"
  cp "$MODEL" "$APP/Contents/Resources/model/"
  echo "  bundled $(basename "$MODEL") ($(du -h "$MODEL" | cut -f1))"
else
  echo "  no model bundled — the app will look for one in ~/.stark/config.json"
fi

# Onboarding backgrounds (optional; gradients are the fallback)
if compgen -G "Backgrounds/*.jpg" > /dev/null; then
  mkdir -p "$APP/Contents/Resources/backgrounds"
  cp Backgrounds/*.jpg "$APP/Contents/Resources/backgrounds/"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Stark</string>
  <key>CFBundleDisplayName</key><string>Stark</string>
  <key>CFBundleIdentifier</key><string>com.local.stark</string>
  <key>CFBundleExecutable</key><string>Stark</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Prefer a stable self-signed identity (./setup_signing.sh) so macOS keeps the
# Accessibility grant across rebuilds; fall back to ad-hoc, which loses it every time.
IDENTITY="Stark Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force -s "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\" — Accessibility grant persists across rebuilds."
else
  codesign --force -s - "$APP"
  echo "Ad-hoc signed. Run ./setup_signing.sh once to stop losing the"
  echo "Accessibility permission on every rebuild."
fi
echo "Built $APP — launch with: open $APP"
