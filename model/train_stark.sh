#!/bin/bash
# Train the Stark LoRA adapter. Usage: ./train_stark.sh [0.5b|1.5b]
# Uses the ~/mlx-finetune venv and its train.py live dashboard (http://localhost:7777).
set -euo pipefail

SIZE="${1:-1.5b}"
case "$SIZE" in
  0.5b) MODEL="mlx-community/Qwen2.5-0.5B-Instruct-4bit" ;;
  1.5b) MODEL="mlx-community/Qwen2.5-1.5B-Instruct-4bit" ;;
  *) echo "usage: $0 [0.5b|1.5b]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
FT=~/mlx-finetune

cd "$FT"
DASH_ONESHOT="${DASH_ONESHOT:-1}" .venv/bin/python train.py \
  --model "$MODEL" \
  --data "$HERE/data" \
  --fine-tune-type lora \
  --num-layers 16 \
  --batch-size 4 \
  --iters 150 \
  --learning-rate 1e-4 \
  --max-seq-length 1024 \
  --steps-per-report 10 \
  --steps-per-eval 25 \
  --save-every 25 \
  --val-batches -1 \
  --adapter-path "$HERE/adapters-$SIZE"
