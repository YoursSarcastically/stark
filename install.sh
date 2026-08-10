#!/bin/bash
# Stark — install from the terminal.
#
#   curl -fsSL https://raw.githubusercontent.com/YoursSarcastically/stark/main/install.sh | bash
#
# Downloads the latest release, puts Stark in /Applications, clears the
# quarantine flag Gatekeeper would otherwise stop it on, and launches it.
# Nothing else is installed: no Python, no Homebrew, no command line tools.
# The app brings its own inference engine and fetches the model on first run.
#
# To uninstall:  rm -rf /Applications/Stark.app ~/.stark \
#                       ~/Library/Application\ Support/Stark
#
# Override the source with STARK_DMG_URL=... to install from your own host.
set -euo pipefail

REPO="${STARK_REPO:-YoursSarcastically/stark}"
say()  { printf "\n\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\n\033[31m%s\033[0m\n" "$1" >&2; exit 1; }

# --- 1. Will it run here? ---------------------------------------------------
say "Checking this Mac…"
[ "$(uname -s)" = "Darwin" ] || fail "Stark is macOS only."
[ "$(uname -m)" = "arm64" ] || fail "Stark needs Apple silicon (M1 or later)."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || fail "Stark needs macOS 14 or later (you have $(sw_vers -productVersion))."

RAM_GB=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')
FREE_GB=$(df -g / | tail -1 | awk '{print $4}')
echo "  macOS $(sw_vers -productVersion) · Apple silicon · ${RAM_GB} GB RAM · ${FREE_GB} GB free"
[ "$RAM_GB" -ge 8 ] || echo "  Note: under 8 GB. Stark needs about 1.2 GB while running."
# The app is small; the model it fetches afterwards is not.
[ "$FREE_GB" -ge 4 ] || fail "Need about 4 GB free, you have ${FREE_GB} GB."

# --- 2. Fetch ---------------------------------------------------------------
if [ -n "${STARK_DMG_URL:-}" ]; then
    URL="$STARK_DMG_URL"
else
    say "Finding the latest release…"
    URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
           | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
           | head -1 | sed 's/.*": *"//; s/"$//')"
    [ -n "$URL" ] || fail "No .dmg in the latest release of $REPO. Set STARK_DMG_URL to install from elsewhere."
fi

TMP="$(mktemp -d)"
# Leave nothing behind, including on a failure or a Ctrl-C partway through.
cleanup() {
    [ -n "${MOUNT:-}" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

say "Downloading Stark…"
curl -fL --progress-bar "$URL" -o "$TMP/Stark.dmg" || fail "Download failed."

# --- 3. Install -------------------------------------------------------------
say "Installing…"
MOUNT="$TMP/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$TMP/Stark.dmg" -nobrowse -quiet -mountpoint "$MOUNT" \
    || fail "Could not open the disk image."
[ -d "$MOUNT/Stark.app" ] || fail "That disk image does not contain Stark.app."

# Quit a running copy first, or the replace lands under a live process and
# macOS kills it mid-flight.
pkill -f "Stark.app/Contents/MacOS/Stark" 2>/dev/null || true
sleep 1

DEST="/Applications/Stark.app"
if [ -w /Applications ]; then
    rm -rf "$DEST"
    cp -R "$MOUNT/Stark.app" "$DEST"
else
    echo "  /Applications needs an administrator; you will be asked for your password."
    sudo rm -rf "$DEST"
    sudo cp -R "$MOUNT/Stark.app" "$DEST"
    sudo chown -R "$(id -u):$(id -g)" "$DEST"
fi

# Stark is signed but not notarized (that needs a paid Apple Developer
# account), so Gatekeeper refuses to open it while the quarantine flag is set.
# Clearing it here is the same thing right-click → Open does, minus the dialog.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# --- 4. Go ------------------------------------------------------------------
say "Starting Stark…"
open "$DEST"

cat <<'EOF'

  Stark is in your menu bar, top right.

  Setup opens by itself and walks you through three things:

    1. Downloading the model — about 1.2 GB, once. It lives in
       ~/Library/Application Support/Stark and survives app updates.
    2. Granting permission — System Settings → Privacy & Security →
       Accessibility. Stark needs it to replace text where you wrote it.
    3. A first rewrite, so you can see it work.

  After that: select text anywhere, press ⌘D.

EOF
