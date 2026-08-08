#!/bin/bash
# Train the predictive-typing (completion) LoRA adapter.
#
# Unlike train_stark.sh — which drives the author's ~/mlx-finetune venv and its
# dashboard — this runs mlx_lm's own LoRA trainer straight from the Stark venv
# (~/.stark/venv), so it works on a clean machine.
#
# IMPORTANT: this trains from the BASE model, not from the fused stark-1.5b.
# The rewrite fine-tune teaches "restate the whole input, improved"; completion
# needs "add only what comes next". Stacking them fights the rewrite habit.
#
# Usage: ./train_completion.sh [0.6b|1.5b]
set -euo pipefail

SIZE="${1:-1.5b}"
case "$SIZE" in
  0.6b) MODEL="mlx-community/Qwen3-0.6B-4bit" ;;
  1.5b) MODEL="mlx-community/Qwen2.5-1.5B-Instruct-4bit" ;;
  *) echo "usage: $0 [0.6b|1.5b]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PY:-$HOME/.stark/venv/bin/python}"

[ -d "$HERE/data-complete" ] || "$PY" "$HERE/make_completion_data.py"

"$PY" -m mlx_lm lora \
  --model "$MODEL" \
  --train \
  --data "$HERE/data-complete" \
  --fine-tune-type lora \
  --num-layers 16 \
  --batch-size 4 \
  --iters 200 \
  --learning-rate 1e-4 \
  --max-seq-length 512 \
  --steps-per-report 10 \
  --steps-per-eval 50 \
  --save-every 50 \
  --adapter-path "$HERE/adapters-complete-$SIZE"

echo ""
echo "Adapter written to $HERE/adapters-complete-$SIZE"
echo "Fuse it into a servable model with:"
echo "  $PY -m mlx_lm fuse --model $MODEL \\"
echo "      --adapter-path $HERE/adapters-complete-$SIZE \\"
echo "      --save-path $HERE/stark-complete-$SIZE"
