#!/usr/bin/env python3
"""
Evaluate a completion model on the held-out sentences from make_completion_data.py.

Run a server first:

    python -m mlx_lm server --model model/stark-complete-0.6b --port 8799
    python eval_completion.py --port 8799

Exact match against one reference is the wrong bar — plenty of continuations are
valid English that simply isn't what the corpus happened to say. So the headline
number here is **leading-word agreement**: how many words the model gets right
before it first diverges from the reference. That's the metric a ghost-text UI
actually cares about, because the user accepts word by word (Tab, Tab, Tab) and
a suggestion is useful right up until the first wrong word.

Also reports first-word accuracy (does the very next Tab help at all?) and
latency, since a correct suggestion that arrives too late is not a suggestion.
"""

import argparse
import json
import os
import random
import statistics
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MIN_PREFIX_WORDS = 2
MIN_CONT_WORDS = 3
MAX_CONT_WORDS = 10


def complete(port, prefix, max_tokens, timeout=30):
    body = json.dumps({
        "messages": [{"role": "system", "content": "complete"},
                     {"role": "user", "content": prefix}],
        "temperature": 0.0,
        "max_tokens": max_tokens,
    }).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=body, headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.load(r)
    dt = (time.perf_counter() - t0) * 1000
    text = out["choices"][0]["message"]["content"]
    for junk in ("<|im_end|>", "<|endoftext|>"):
        text = text.replace(junk, "")
    return text.strip(), dt


def leading_match(pred, ref):
    """Number of leading words that agree (case/punctuation-insensitive)."""
    def norm(w):
        return w.lower().strip(".,!?;:'\"")
    p, r = [norm(w) for w in pred.split()], [norm(w) for w in ref.split()]
    n = 0
    for a, b in zip(p, r):
        if a != b:
            break
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--n", type=int, default=60, help="sentences to sample")
    ap.add_argument("--show", type=int, default=8, help="qualitative samples to print")
    args = ap.parse_args()

    path = os.path.join(HERE, "data-complete", "eval_sentences.json")
    sentences = json.load(open(path, encoding="utf-8"))
    rng = random.Random(11)
    rng.shuffle(sentences)

    matches, firsts, lats, shown = [], [], [], []
    for s in sentences[:args.n]:
        words = s.split()
        lo, hi = MIN_PREFIX_WORDS, len(words) - MIN_CONT_WORDS
        if hi <= lo:
            continue
        cut = rng.randint(lo, hi)
        prefix = " ".join(words[:cut])
        ref = " ".join(words[cut:cut + MAX_CONT_WORDS])
        try:
            pred, dt = complete(args.port, prefix, MAX_CONT_WORDS * 3)
        except Exception as e:
            print(f"request failed: {e}")
            return
        n = leading_match(pred, ref)
        matches.append(n)
        firsts.append(1 if n >= 1 else 0)
        lats.append(dt)
        if len(shown) < args.show:
            shown.append((prefix, ref, pred, n))

    if not matches:
        print("no usable eval sentences")
        return

    print(f"samples                 {len(matches)}")
    print(f"first-word accuracy     {100*statistics.mean(firsts):.1f}%")
    print(f"leading words correct   mean {statistics.mean(matches):.2f}  "
          f"median {statistics.median(matches):.0f}  max {max(matches)}")
    print(f"latency                 mean {statistics.mean(lats):.0f} ms  "
          f"p50 {statistics.median(lats):.0f} ms")
    print()
    for prefix, ref, pred, n in shown:
        print(f"  prefix : …{prefix[-52:]}")
        print(f"  ref    : {ref}")
        print(f"  pred   : {pred}   [{n} leading words correct]")
        print()


if __name__ == "__main__":
    main()
