#!/bin/bash
# Build Stark.app (release) into app/build/. Run once, then open build/Stark.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Stark.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The app icon, drawn by tools/make_icon.py. Regenerate with:
#   python tools/make_icon.py
if [ -f Stark.icns ]; then
  cp Stark.icns "$APP/Contents/Resources/Stark.icns"
else
  echo "  no Stark.icns — run tools/make_icon.py"
fi
cp .build/release/Stark "$APP/Contents/MacOS/Stark"

# The inference engine. Binary and dylibs must land in one directory: the
# binary's LC_RPATH is @loader_path, so they resolve each other by proximity.
# Without this the app is useless on any machine but the one that built it.
ENGINE="../vendor/llama-b10333"
if [ -x "$ENGINE/llama-server" ]; then
  mkdir -p "$APP/Contents/Resources/llama"
  cp "$ENGINE/llama-server" "$APP/Contents/Resources/llama/"
  # Copy one real file per library and symlink its aliases. llama.cpp ships
  # each dylib three times over (libfoo.dylib, libfoo.0.dylib,
  # libfoo.0.19.0.dylib), which is 53 MB of the same 24 MB of code.
  for lib in "$ENGINE"/*.dylib; do
    base="$(basename "$lib")"
    [ -L "$lib" ] && continue
    cp "$lib" "$APP/Contents/Resources/llama/$base"
  done
  ( cd "$APP/Contents/Resources/llama"
    for full in *.[0-9]*.[0-9]*.[0-9]*.dylib; do
      [ -e "$full" ] || continue
      stem="${full%%.*}"
      major="$(echo "$full" | sed -E 's/^[^.]+\.([0-9]+)\..*/\1/')"
      for alias in "$stem.dylib" "$stem.$major.dylib"; do
        [ "$alias" = "$full" ] && continue
        rm -f "$alias"; ln -s "$full" "$alias"
      done
    done )
  echo "  bundled llama-server ($(du -sh "$APP/Contents/Resources/llama" | cut -f1))"
else
  echo "  ⚠️  vendor/llama-b10333/llama-server missing — the app will not run."
  echo "     Fetch it: see vendor/README.md"
fi

# The weights, off by default.
#
# Bundling them made a 1.28 GB download, of which 1.2 GB was one file that does
# not change between releases — so every user re-downloaded the model to get a
# 2 MB app fix. The app now fetches it once on first run, with a progress bar,
# and keeps it in Application Support where an app update cannot disturb it.
#
# Set STARK_BUNDLE_MODEL=1 for an offline build that needs no network at all.
if [ "${STARK_BUNDLE_MODEL:-0}" = "1" ]; then
  MODEL="${STARK_MODEL:-../model/stark-1.7b-Q5_K_M.gguf}"
  if [ -f "$MODEL" ]; then
    mkdir -p "$APP/Contents/Resources/model"
    cp "$MODEL" "$APP/Contents/Resources/model/"
    echo "  bundled $(basename "$MODEL") ($(du -h "$MODEL" | cut -f1))"
  else
    echo "  STARK_BUNDLE_MODEL=1 but $MODEL is missing"
  fi
else
  echo "  no model bundled — fetched on first run"
fi

# Onboarding demo animations. Regenerate with tools/make_demos.py; the app
# falls back to live SwiftUI reconstructions when they are absent.
if compgen -G "Demos/*.gif" > /dev/null; then
  mkdir -p "$APP/Contents/Resources/demos"
  cp Demos/*.gif "$APP/Contents/Resources/demos/"
  echo "  bundled $(ls Demos/*.gif | wc -l | tr -d ' ') demo animations"
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
  <key>CFBundleIconFile</key><string>Stark</string>
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
