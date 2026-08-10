#!/bin/bash
# Stark — check an installation and say what is wrong with it.
#
#   curl -fsSL https://raw.githubusercontent.com/YoursSarcastically/stark/main/tools/doctor.sh | bash
#
# Prints a short report. Nothing is changed, nothing is uploaded — the output
# is for the person running it to read, and to paste back if they want help.
#
# The one line that matters is "Stark launches". Gatekeeper rejecting the
# signature is expected and harmless: Stark is signed with a certificate that
# only exists on the machine that built it, and macOS only consults that
# signature for files carrying a quarantine flag. Installed via install.sh
# there is no quarantine flag, so the check never runs.

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
info() { printf "    %s\n" "$1"; }
head_() { printf "\n\033[1m%s\033[0m\n" "$1"; }

APP="/Applications/Stark.app"
MODEL="$HOME/Library/Application Support/Stark/stark-1.7b-Q5_K_M.gguf"
MODEL_BYTES=1257879776
PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS + 1)); }

head_ "This Mac"
printf "  macOS %s · %s · %s GB RAM\n" \
    "$(sw_vers -productVersion)" "$(uname -m)" \
    "$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')"
[ "$(uname -m)" = "arm64" ] || { bad "Not Apple silicon. Stark will not run here."; note_problem; }
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || { bad "macOS 14 or later required."; note_problem; }

head_ "The app"
if [ -d "$APP" ]; then
    ok "Installed at $APP"
    VER=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    [ -n "$VER" ] && info "version $VER"

    if codesign --verify --strict "$APP" 2>/dev/null; then
        ok "Signature intact"
    else
        bad "Signature is broken — the copy is damaged. Reinstall."
        note_problem
    fi

    if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
        bad "Quarantined — macOS will refuse to open it"
        info "Fix: xattr -dr com.apple.quarantine $APP"
        note_problem
    else
        ok "Not quarantined (this is why it opens despite the signature)"
    fi

    # Reported for completeness. A rejection here is expected and does not
    # stop the app opening; see the note at the top of this script.
    SPCTL=$(spctl -a -vv -t exec "$APP" 2>&1 | tail -1)
    info "Gatekeeper assessment: ${SPCTL#*: }"
else
    bad "Stark is not in /Applications"
    info "Install: curl -fsSL https://raw.githubusercontent.com/YoursSarcastically/stark/main/install.sh | bash"
    note_problem
fi

head_ "The model"
if [ -f "$MODEL" ]; then
    SZ=$(stat -f%z "$MODEL" 2>/dev/null || echo 0)
    if [ "$SZ" -eq "$MODEL_BYTES" ]; then
        ok "Downloaded ($((SZ / 1048576)) MB)"
    else
        bad "Incomplete: $((SZ / 1048576)) MB of $((MODEL_BYTES / 1048576)) MB"
        info "Open Stark and finish it from the setup window, or run install.sh again."
        note_problem
    fi
else
    bad "Not downloaded yet"
    info "Stark's setup window will offer to fetch it."
    note_problem
fi

head_ "Running"
if pgrep -f "Stark.app/Contents/MacOS/Stark" >/dev/null 2>&1; then
    ok "Stark launches"
else
    info "Not running — starting it to check…"
    open "$APP" 2>/dev/null
    sleep 6
    if pgrep -f "Stark.app/Contents/MacOS/Stark" >/dev/null 2>&1; then
        ok "Stark launches"
    else
        bad "Stark will not start"
        info "This is the failure that matters. Paste this whole report back."
        note_problem
    fi
fi

# The inference server is spawned by the app and takes a few seconds.
if curl -s -m 3 http://127.0.0.1:8765/health 2>/dev/null | grep -q ok; then
    ok "Model server responding"
elif [ -f "$MODEL" ]; then
    info "Model server not up yet — it needs ~10 seconds after launch."
fi

head_ "Permission"
info "Accessibility cannot be read from a script. Check by hand:"
info "System Settings → Privacy & Security → Accessibility → Stark must be on."
info "Without it ⌘D does nothing, and that is the most common complaint."

if [ "$PROBLEMS" -eq 0 ]; then
    printf "\n\033[32mAll good.\033[0m Select some text anywhere and press ⌘D.\n\n"
else
    if [ "$PROBLEMS" -eq 1 ]; then
        printf "\n\033[33mOne thing above needs attention.\033[0m\n\n"
    else
        printf "\n\033[33m%s things above need attention.\033[0m\n\n" "$PROBLEMS"
    fi
fi
