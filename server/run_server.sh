#!/bin/bash
# Run the Stark model server standalone (the app normally manages this itself).
# Env overrides: PORT, MODEL, ADAPTER.
set -euo pipefail

# Serves the fused fine-tuned model. (Note: --adapter-path is silently ignored
# by mlx_lm 0.31.3's server due to an upstream map-lookup bug, so we fuse.)
PORT="${PORT:-8765}"
MODEL="${MODEL:-$HOME/Stark/model/stark-1.5b}"

ARGS=(--model "$MODEL" --host 127.0.0.1 --port "$PORT")

HF_HUB_OFFLINE=1 exec "$HOME/mlx-finetune/.venv/bin/python" -m mlx_lm server "${ARGS[@]}"
