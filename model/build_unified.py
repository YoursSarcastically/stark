#!/usr/bin/env python3
"""Merge the rewrite and completion corpora into data-unified/ for joint training.

Rewrite rows are upsampled 2x: completion has ~4x the volume, and without this
the one-press rewrite presets get drowned out by continuation examples.
"""
import json, os, random

HERE = os.path.dirname(os.path.abspath(__file__))
REWRITE_UPSAMPLE = 2


def load(p):
    return [json.loads(l) for l in open(p, encoding="utf-8")] if os.path.exists(p) else []


def main():
    rng = random.Random(0x11FED)
    os.makedirs(os.path.join(HERE, "data-unified"), exist_ok=True)
    for split in ("train", "valid"):
        base = load(os.path.join(HERE, "data", f"{split}.jsonl"))
        hard = load(os.path.join(HERE, "data-hardening", f"{split}.jsonl"))
        comp = load(os.path.join(HERE, "data-complete", f"{split}.jsonl"))
        rows = (base + hard) * REWRITE_UPSAMPLE + comp
        rng.shuffle(rows)
        out = os.path.join(HERE, "data-unified", f"{split}.jsonl")
        with open(out, "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"{split}: {len(rows)} rows "
              f"(rewrite {len(base)+len(hard)}x{REWRITE_UPSAMPLE} + completion {len(comp)})")


if __name__ == "__main__":
    main()
