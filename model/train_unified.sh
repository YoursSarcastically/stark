#!/bin/bash
# Train ONE LoRA adapter that does both jobs — rewriting and completion.
#
# There is no reason for two models. The system tag already says which job it
# is ("polish", "typos", … vs "complete"), so a single adapter trained on the
# union learns both and the app loads one ~1 GB model instead of two. Joint
# training also acts as mild regularisation: the completion data teaches the
# model to continue text rather than restate it, which is exactly the instinct
# that stops "who is you" turning into a chatbot answer.
#
# Base model, not the fused rewrite model: stacking adapters on a fused
# fine-tune fights the habits already baked in.
#
# Usage: ./train_unified.sh [1.7b|1.5b]
set -euo pipefail

SIZE="${1:-1.7b}"
case "$SIZE" in
  # Qwen3. Hybrid-thinking model: serve it with
  #   --chat-template-args '{"enable_thinking":false}'
  # or it emits <think> blocks and the latency story collapses.
  1.7b) MODEL="mlx-community/Qwen3-1.7B-4bit" ;;
  0.6b) MODEL="mlx-community/Qwen3-0.6B-4bit" ;;
  # Qwen2.5 fallback — no thinking mode, but an older generation.
  1.5b) MODEL="mlx-community/Qwen2.5-1.5B-Instruct-4bit" ;;
  *) echo "usage: $0 [1.7b|0.6b|1.5b]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PY:-$HOME/.stark/venv/bin/python}"

# Rebuild both halves, then merge (rewrite upsampled 2x — see build_unified.py).
"$PY" "$HERE/make_stark_data.py"
"$PY" "$HERE/make_hardening_data.py"
"$PY" "$HERE/make_completion_data.py"
"$PY" "$HERE/build_unified.py"

"$PY" -m mlx_lm lora \
  --model "$MODEL" \
  --train \
  --data "$HERE/data-unified" \
  --fine-tune-type lora \
  --num-layers 16 \
  --batch-size 4 \
  --iters 600 \
  --learning-rate 1e-4 \
  --max-seq-length 1024 \
  --steps-per-report 25 \
  --steps-per-eval 150 \
  --save-every 150 \
  --adapter-path "$HERE/adapters-unified-$SIZE"

echo ""
echo "Fusing into a single servable model…"
"$PY" -m mlx_lm fuse --model "$MODEL" \
  --adapter-path "$HERE/adapters-unified-$SIZE" \
  --save-path "$HERE/stark-$SIZE"
echo "Done: $HERE/stark-$SIZE  (serves every preset AND 'complete')"
