#!/usr/bin/env python3
"""Aura: retrain Stark on the user's accepted rewrites.

Reads ~/.stark/aura/pairs.jsonl (written by the app), keeps the newest record
per pair (an undo re-logs the pair as rejected), mixes accepted pairs into the
original synthetic dataset so the model doesn't forget its styles, runs a
short LoRA pass on top of the current fused model, fuses the result, and
swaps it in — keeping the previous model as stark-1.5b.prev for rollback.

Everything runs locally. Env knobs:
  AURA_MIN_PAIRS (default 8)   minimum accepted pairs to bother training
  AURA_ITERS     (default 80)  LoRA iterations
  AURA_SWAP      (default 1)   0 = train and fuse but leave the live model alone
"""
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime

HOME = os.path.expanduser("~")
MODEL_DIR = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(MODEL_DIR, "stark-1.5b")
ADAPTERS = os.path.join(MODEL_DIR, "adapters-aura")
AURA_DIR = os.path.join(HOME, ".stark", "aura")
PAIRS = os.path.join(AURA_DIR, "pairs.jsonl")
LOG = os.path.join(AURA_DIR, "train.log")

MIN_PAIRS = int(os.environ.get("AURA_MIN_PAIRS", "8"))
ITERS = int(os.environ.get("AURA_ITERS", "80"))
SWAP = os.environ.get("AURA_SWAP", "1") == "1"


def log(msg):
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line, flush=True)
    os.makedirs(AURA_DIR, exist_ok=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def load_pairs():
    """Newest record wins per (tag, input); keep accepted ones."""
    latest = {}
    try:
        with open(PAIRS) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    p = json.loads(line)
                except json.JSONDecodeError:
                    continue
                latest[(p.get("tag", ""), p.get("input", ""))] = p
    except FileNotFoundError:
        return []
    return [p for p in latest.values()
            if p.get("accepted") and p.get("input") and p.get("output")]


def to_chat(p):
    return {"messages": [
        {"role": "system", "content": p["tag"]},
        {"role": "user", "content": p["input"]},
        {"role": "assistant", "content": p["output"]},
    ]}


def run(cmd):
    log("$ " + " ".join(cmd))
    with open(LOG, "a") as f:
        subprocess.run(cmd, check=True, stdout=f, stderr=subprocess.STDOUT)


def main():
    pairs = load_pairs()
    log(f"aura pairs: {len(pairs)} accepted (min {MIN_PAIRS})")
    if len(pairs) < MIN_PAIRS:
        log("not enough pairs yet — skipping")
        return 2

    data_dir = tempfile.mkdtemp(prefix="aura_data_")
    with open(os.path.join(MODEL_DIR, "data", "train.jsonl")) as f:
        synthetic = [line.strip() for line in f if line.strip()]
    user = [json.dumps(to_chat(p), ensure_ascii=False) for p in pairs]
    mixed = synthetic + user * 3  # oversample the user's voice
    random.seed(7)
    random.shuffle(mixed)
    with open(os.path.join(data_dir, "train.jsonl"), "w") as f:
        f.write("\n".join(mixed) + "\n")
    shutil.copy(os.path.join(MODEL_DIR, "data", "valid.jsonl"),
                os.path.join(data_dir, "valid.jsonl"))
    log(f"dataset: {len(synthetic)} synthetic + {len(user)}x3 user pairs")

    py = sys.executable
    shutil.rmtree(ADAPTERS, ignore_errors=True)
    run([py, "-m", "mlx_lm", "lora",
         "--model", BASE, "--train", "--data", data_dir,
         "--fine-tune-type", "lora", "--num-layers", "16",
         "--batch-size", "4", "--iters", str(ITERS),
         "--learning-rate", "5e-5", "--max-seq-length", "1024",
         "--save-every", str(ITERS), "--steps-per-eval", str(max(ITERS // 2, 1)),
         "--adapter-path", ADAPTERS])

    new = BASE + ".new"
    shutil.rmtree(new, ignore_errors=True)
    run([py, "-m", "mlx_lm", "fuse",
         "--model", BASE, "--adapter-path", ADAPTERS, "--save-path", new])

    if not SWAP:
        log(f"AURA_SWAP=0 — new model left at {new}, live model untouched")
        return 0

    prev = BASE + ".prev"
    shutil.rmtree(prev, ignore_errors=True)
    os.rename(BASE, prev)
    os.rename(new, BASE)
    log("model swapped in; previous kept at stark-1.5b.prev")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 — anything fatal lands in the log
        log(f"FAILED: {e}")
        sys.exit(1)
