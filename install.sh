#!/bin/bash
# Stark — install from the terminal.
#
#   curl -fsSL https://raw.githubusercontent.com/YoursSarcastically/stark/main/install.sh | bash
#
# Downloads the app and the model, puts Stark in /Applications, clears the
# quarantine flag Gatekeeper would otherwise stop it on, and launches it.
# Nothing else is installed: no Python, no Homebrew, no command line tools.
# The app brings its own inference engine, so this and the weights are all
# that ever touch the machine.
#
# To uninstall:  rm -rf /Applications/Stark.app ~/.stark \
#                       ~/Library/Application\ Support/Stark
#
# Override the source with STARK_DMG_URL=... to install from your own host.
set -euo pipefail

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
# GitHub Releases first, Hugging Face second.
#
# Both work; GitHub is simply faster. Measured back to back on one connection:
# 3.8 MB/s from GitHub's release CDN against 0.7 MB/s from Hugging Face, and
# on a 1.2 GB model that is the difference between five minutes and half an
# hour. Hugging Face stays as the fallback so a missing or half-published
# release cannot leave anyone stranded.
GH_RELEASE="https://github.com/YoursSarcastically/stark/releases/latest/download"
HF_FILES="https://huggingface.co/suraj10620/stark-1.7b-gguf/resolve/main"

# Prefers the first URL that actually answers, rather than assuming.
#
# Two attempts each, and a one-byte ranged GET rather than a HEAD: a freshly
# published release asset can blip for a few seconds, and a single failed
# probe would quietly drop every user onto the slower host for no reason. The
# ranged GET also exercises the same path the real download takes.
pick_url() {
    for candidate in "$@"; do
        for attempt in 1 2; do
            if curl -fsL -m 15 -r 0-0 -o /dev/null "$candidate" 2>/dev/null; then
                printf '%s' "$candidate"
                return 0
            fi
            [ "$attempt" = 1 ] && sleep 2
        done
    done
    return 1
}

if [ -n "${STARK_DMG_URL:-}" ]; then
    URL="$STARK_DMG_URL"
else
    URL="$(pick_url "$GH_RELEASE/Stark.dmg" "$HF_FILES/Stark.dmg")" \
        || fail "Could not reach GitHub or Hugging Face to download Stark."
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

# --- 4. The model -----------------------------------------------------------
# Fetched here rather than left to the app's first run. Someone who installed
# from a terminal expects to end up with a working app, not with a 1.2 GB
# download still ahead of them. The app looks in exactly this place, so if it
# is already here setup skips the step entirely.
MODEL_DIR="$HOME/Library/Application Support/Stark"
MODEL_NAME="stark-1.7b-Q5_K_M.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
MODEL_BYTES=1257879776
MODEL_SHA=7a2af84dd97030b660bcf6ae2d7ec11d0b43c3f5cdb204b2d2eea0663c7697b8
if [ -n "${STARK_MODEL_URL:-}" ]; then
    MODEL_URL="$STARK_MODEL_URL"
else
    MODEL_URL="$(pick_url "$GH_RELEASE/$MODEL_NAME" "$HF_FILES/$MODEL_NAME")" \
        || fail "Could not reach GitHub or Hugging Face to download the model."
fi

mkdir -p "$MODEL_DIR"
have_model() {
    [ -f "$MODEL_PATH" ] && [ "$(stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)" -eq "$MODEL_BYTES" ]
}

if have_model; then
    say "Model already downloaded."
else
    # Only resume a partial that came from this same URL. Resuming a
    # GitHub download onto bytes fetched from Hugging Face produced a file of
    # exactly the right length whose digest was wrong — caught by the check
    # below, but only after the full 1.2 GB had been pulled.
    SOURCE_MARK="$MODEL_DIR/.$MODEL_NAME.source"
    if [ -f "$MODEL_PATH" ] && [ "$(cat "$SOURCE_MARK" 2>/dev/null)" != "$MODEL_URL" ]; then
        echo "  A partial download from a different source was found; starting fresh."
        rm -f "$MODEL_PATH"
    fi
    printf '%s' "$MODEL_URL" > "$SOURCE_MARK"

    say "Downloading the model (1.2 GB, one time)…"
    echo "  This is the whole product — it runs on your Mac, so it has to live here."
    # -C - resumes a partial file, so a dropped connection costs only what was
    # left rather than the whole 1.2 GB.
    if ! curl -fL -C - --progress-bar "$MODEL_URL" -o "$MODEL_PATH"; then
        echo "  Download interrupted. Run this installer again to pick up where it stopped."
        echo "  Stark will also offer to finish it from the setup window."
        MODEL_INCOMPLETE=1
    fi
fi

if [ -f "$MODEL_PATH" ] && ! have_model && [ -z "${MODEL_INCOMPLETE:-}" ]; then
    GOT_SZ=$(stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)
    echo "  Got $GOT_SZ bytes, expected $MODEL_BYTES. Discarding and starting over."
    rm -f "$MODEL_PATH" "$MODEL_DIR/.$MODEL_NAME.source"
    say "Downloading the model again…"
    curl -fL --progress-bar "$MODEL_URL" -o "$MODEL_PATH" || MODEL_INCOMPLETE=1
    printf '%s' "$MODEL_URL" > "$MODEL_DIR/.$MODEL_NAME.source"
fi

if have_model; then
    say "Checking the download…"
    # A truncated or corrupt GGUF does not fail loudly: llama-server exits with
    # a parse error that means nothing to the person who sees it.
    GOT="$(shasum -a 256 "$MODEL_PATH" | cut -d' ' -f1)"
    if [ "$GOT" = "$MODEL_SHA" ]; then
        # Recording it here saves the app hashing 1.2 GB again on first launch.
        printf '%s' "$MODEL_SHA" > "$MODEL_DIR/.$MODEL_NAME.verified"
        echo "  Verified."
    else
        rm -f "$MODEL_PATH" "$MODEL_DIR/.$MODEL_NAME.verified" "$MODEL_DIR/.$MODEL_NAME.source"
        fail "The model arrived damaged and has been deleted. Run the installer again."
    fi
fi

# --- 5. Go ------------------------------------------------------------------
# Always show setup after installing. It is where the Accessibility permission
# gets explained, and without it people are left with a menu bar icon and no
# idea what to do with it. The model step will already be ticked off.
CONFIG="$HOME/.stark/config.json"
if [ -f "$CONFIG" ]; then
    plutil -replace onboarded -bool false "$CONFIG" 2>/dev/null || true
fi

say "Starting Stark…"
open "$DEST"

cat <<'EOF'

  Stark is in your menu bar, top right.

  Setup opens by itself. One thing still needs you:

    Granting permission — System Settings → Privacy & Security →
    Accessibility. Stark needs it to replace text where you wrote it.

  Then: select text anywhere, press ⌘D.

EOF

if [ -n "${MODEL_INCOMPLETE:-}" ]; then
    printf "  \033[33mThe model download did not finish — setup will offer to resume it.\033[0m\n\n"
fi
