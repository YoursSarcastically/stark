#!/usr/bin/env python3
"""
Evaluate a Stark adapter on held-out inputs (none appear in training data).

For each preset: generate with the tuned model (and optionally the raw base
model for comparison), report time-to-first-token, generation speed, and peak
memory. Usage:

  python eval_stark.py --model mlx-community/Qwen2.5-1.5B-Instruct-4bit \
      --adapter ./adapters-1.5b [--compare-base] [--max-tokens 512]
"""
import argparse
import json
import time

from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

TESTS = [
    ("polish",
     "we was suppose to send the report friday but the data pipeline were broken so its delayed to monday"),
    ("concise",
     "I just wanted to take a moment to reach out to you in order to see whether or not you might have some availability at some point during the course of next week for a quick call to discuss the current status of the project."),
    ("formal",
     "hey, the build is broken again, can someone look at it? kinda blocking everyone rn"),
    ("friendly",
     "Your submission has been rejected due to incomplete documentation. Resubmit with the required fields."),
    ("typos",
     "The new dashbaord is definately faster, but their are still some isues with teh export button."),
    ("bullets",
     "For launch day we need to freeze the code by Tuesday, notify all enterprise customers by email, prepare the rollback script, and make sure support has the new FAQ."),
    ("prompt",
     "write about remote work"),
    ("expand",
     "Deploy went fine. Monitoring for issues."),
]

PREAMBLE_MARKERS = (
    "here is", "here's", "sure", "certainly", "below is", "i have", "i've",
    "rewritten", "of course",
)


def run(model, tokenizer, tag, text, max_tokens):
    messages = [{"role": "system", "content": tag},
                {"role": "user", "content": text}]
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    sampler = make_sampler(temp=0.0)

    t0 = time.perf_counter()
    ttft = None
    last = None
    out = []
    for resp in stream_generate(model, tokenizer, prompt,
                                max_tokens=max_tokens, sampler=sampler):
        if ttft is None:
            ttft = time.perf_counter() - t0
        out.append(resp.text)
        last = resp
    total = time.perf_counter() - t0
    text_out = "".join(out).strip()
    return {
        "output": text_out,
        "ttft_s": round(ttft or 0, 3),
        "total_s": round(total, 3),
        "gen_tps": round(last.generation_tps, 1) if last else 0,
        "prompt_tps": round(last.prompt_tps, 1) if last else 0,
        "peak_mem_gb": round(last.peak_memory, 2) if last else 0,
        "clean_start": not text_out.lower().startswith(PREAMBLE_MARKERS),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter", default=None)
    ap.add_argument("--compare-base", action="store_true")
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    results = {}
    variants = [("tuned", args.adapter)]
    if args.compare_base:
        variants.append(("base", None))

    for label, adapter in variants:
        if label == "tuned" and adapter is None:
            continue
        print(f"\n{'=' * 70}\n{label.upper()}: {args.model}"
              + (f" + {adapter}" if adapter else ""))
        model, tokenizer = load(args.model, adapter_path=adapter)
        results[label] = {}
        for tag, text in TESTS:
            r = run(model, tokenizer, tag, text, args.max_tokens)
            results[label][tag] = r
            print(f"\n--- [{tag}]  ttft {r['ttft_s']}s · total {r['total_s']}s · "
                  f"{r['gen_tps']} tok/s · peak {r['peak_mem_gb']} GB · "
                  f"clean_start={r['clean_start']}")
            print(f"IN : {text[:120]}")
            print(f"OUT: {r['output'][:600]}")
        del model

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(results, f, indent=2, ensure_ascii=False)
        print(f"\nwrote {args.json_out}")


if __name__ == "__main__":
    main()
