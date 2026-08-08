#!/bin/bash
# Build Stark.app (release) into app/build/. Run once, then open build/Stark.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Stark.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stark "$APP/Contents/MacOS/Stark"

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

codesign --force -s - "$APP"
echo "Built $APP — launch with: open $APP"
