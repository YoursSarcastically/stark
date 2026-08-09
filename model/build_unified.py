#!/usr/bin/env python3
"""Merge every corpus into data-unified/ with PER-TAG balancing.

Naive concatenation is what broke `expand`. Completion generates far more rows
than any rewrite preset, so merging by simple append left the corpus at 68.6%
`complete` and 1.6% `expand` — down from 11.6% in the original 207-pair set —
and expand degraded to near-uselessness.

So the merge targets a row count per tag instead: under-represented tags are
upsampled toward the target, over-represented ones are capped. `complete` gets
a larger share (it is a harder, more open-ended task and has genuinely more
distinct data) but nowhere near a majority.
"""
import json, os, random
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = ["data", "data-hardening", "data-presets", "data-complete"]

# Rows per tag after balancing.
TARGET = defaultdict(lambda: 320)
TARGET["complete"] = 1100          # harder task, most genuinely-distinct data
TARGET["prompt"] = 220             # few distinct examples; heavy upsampling overfits


def load(split):
    rows = []
    for src in SOURCES:
        p = os.path.join(HERE, src, f"{split}.jsonl")
        if os.path.exists(p):
            rows += [json.loads(l) for l in open(p, encoding="utf-8")]
    return rows


def balance(rows, rng):
    by_tag = defaultdict(list)
    for r in rows:
        by_tag[r["messages"][0]["content"]].append(r)
    out = []
    for tag, items in by_tag.items():
        target = TARGET[tag]
        rng.shuffle(items)
        if len(items) >= target:
            out += items[:target]
        else:
            # Repeat whole passes, then a partial one, so every distinct example
            # is seen the same number of times (+/- 1) rather than at random.
            reps, rem = divmod(target, len(items))
            out += items * reps + items[:rem]
    return out


def main():
    rng = random.Random(0x11FED)
    for split in ("train", "valid"):
        rows = load(split)
        if split == "train":
            rows = balance(rows, rng)
        rng.shuffle(rows)
        out = os.path.join(HERE, "data-unified", f"{split}.jsonl")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        counts = defaultdict(int)
        for r in rows:
            counts[r["messages"][0]["content"]] += 1
        print(f"{split}: {len(rows)} rows")
        if split == "train":
            for tag in sorted(counts, key=lambda t: -counts[t]):
                print(f"   {tag:10s} {counts[tag]:5d}  {100*counts[tag]/len(rows):5.1f}%")


if __name__ == "__main__":
    main()
