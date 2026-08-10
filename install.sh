#!/bin/bash
# Stark — one-command setup.
#
#   git clone https://github.com/YoursSarcastically/stark.git ~/Stark
#   cd ~/Stark && ./install.sh
#
# Builds the app, sets up a private Python environment for the model server,
# downloads the weights, and launches. Everything it creates lives in ~/.stark
# and this folder, so uninstalling is `rm -rf ~/.stark ~/Stark`.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

say() { printf "\n\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\n\033[31m%s\033[0m\n" "$1" >&2; exit 1; }

# --- 1. Machine ------------------------------------------------------------
say "Checking this Mac…"
[ "$(uname -s)" = "Darwin" ] || fail "Stark is macOS only."
[ "$(uname -m)" = "arm64" ] || fail "Stark needs Apple silicon (M1/M2/M3/M4 or A-series)."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || fail "Stark needs macOS 14 or later (you have $(sw_vers -productVersion))."

RAM_GB=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')
echo "  macOS $(sw_vers -productVersion) · Apple silicon · ${RAM_GB} GB RAM"
[ "$RAM_GB" -ge 8 ] || echo "  ⚠️  Under 8 GB — the model needs about 1.2 GB while running."

if ! xcode-select -p >/dev/null 2>&1; then
    fail "Command Line Tools missing. Run: xcode-select --install"
fi

FREE_GB=$(df -g / | tail -1 | awk '{print $4}')
[ "$FREE_GB" -ge 4 ] || fail "Need ~4 GB free; you have ${FREE_GB} GB."

# --- 2. Python environment -------------------------------------------------
# Private to Stark so it can't collide with anything else on the machine.
say "Setting up the model runtime (~1 min)…"
VENV="$HOME/.stark/venv"
if [ ! -x "$VENV/bin/python" ]; then
    mkdir -p "$HOME/.stark"
    /usr/bin/python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q mlx-lm huggingface_hub 2>&1 | grep -v "NotOpenSSL" || true
echo "  mlx-lm $("$VENV/bin/python" -c 'import mlx_lm; print(mlx_lm.__version__)' 2>/dev/null)"

# --- 3. Model --------------------------------------------------------------
MODEL_REPO="${STARK_MODEL_REPO:-suraj10620/stark-1.7b}"
MODEL_DIR="$HERE/model/$(basename "$MODEL_REPO")"
if [ ! -f "$MODEL_DIR/config.json" ]; then
    say "Downloading the model (~900 MB, one time)…"
    "$VENV/bin/hf" download "$MODEL_REPO" --local-dir "$MODEL_DIR"
else
    say "Model already present."
fi

# Some published checkpoints store `extra_special_tokens` as a list; recent
# transformers requires a dict and crashes on load otherwise.
"$VENV/bin/python" - "$MODEL_DIR" <<'PY' 2>/dev/null || true
import json, os, re, shutil, sys
p = os.path.join(sys.argv[1], "tokenizer_config.json")
if os.path.exists(p):
    d = json.load(open(p))
    est = d.get("extra_special_tokens")
    if isinstance(est, list):
        shutil.copy(p, p + ".orig")
        d["extra_special_tokens"] = {re.sub(r"\W+", "_", t.strip("<|>")): t for t in est}
        json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
        print("  patched tokenizer config")
PY

# --- 4. Config -------------------------------------------------------------
CONFIG="$HOME/.stark/config.json"
if [ ! -f "$CONFIG" ]; then
    say "Writing ~/.stark/config.json…"
    cat > "$CONFIG" <<EOF
{
  "port": 8765,
  "python": "~/.stark/venv/bin/python",
  "model": "$MODEL_DIR",
  "maxTokens": 4096,
  "temperature": 0.2,
  "hotkey": "ctrl+alt+s",
  "preset": "polish"
}
EOF
else
    echo "  Keeping your existing ~/.stark/config.json"
fi

# --- 5. Build --------------------------------------------------------------
say "Building Stark…"
( cd app && ./make_app.sh >/dev/null )
echo "  built app/build/Stark.app"

# --- 6. Launch -------------------------------------------------------------
say "Starting Stark…"
open app/build/Stark.app

cat <<'EOF'

  Stark is in your menu bar (the ⚡ icon). Two things to finish:

  1. Grant Accessibility. macOS will ask, or:
     System Settings → Privacy & Security → Accessibility → enable Stark.
     Rewriting text needs it — that is how the copy and paste happen.

  2. Give the model ~10 seconds to warm up, then select some text
     anywhere and press ⌃⌥S.

  Predictive typing (ghost-text suggestions as you type) is off by
  default: menu bar → Predictive Typing.

EOF
