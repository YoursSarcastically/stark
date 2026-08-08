#!/usr/bin/env python3
"""
Generate the *completion* dataset — the predictive-typing counterpart to
make_stark_data.py.

Why a separate dataset (and a separate adapter): the rewrite fine-tune teaches
the model to emit a full rewritten COPY of its input. Continuation is the
opposite job — read a half-finished sentence and produce only the next few
words, never restating what's already there. Training completion on top of the
fused rewrite model fights that habit, so this trains a fresh adapter from the
same BASE model instead.

Three sources of sentences, because diversity — not row count — is what makes a
completion model stop reciting memorised phrases:

  1. HARVESTED  — every realistic sentence already written for the rewrite
                  corpus in make_stark_data.py (parsed via `ast`, so escapes and
                  UTF-8 survive). Hundreds of sentences, already in the product's
                  own register, free.
  2. AUTHORED   — hand-written short-form messages across chat/email/notes/technical.
  3. TEMPLATED  — combinatorial generation over openers × predicates × objects ×
                  tails, which supplies the long tail of phrasings that hand-writing
                  can't reach.

Each sentence is cut at several points into (prefix, continuation) pairs.

    system:    "complete"
    user:      "hey, are you free to"
    assistant: " hop on a quick call later today?"

The leading space on the assistant side is deliberate: the model must produce
text that concatenates onto the prefix verbatim, with no trimming or joining.

IMPORTANT: the train/valid split is by SOURCE SENTENCE, not by pair. Splitting
by pair leaks — two cuts of the same sentence land on both sides and validation
loss then measures memorisation instead of generalisation.

Writes data-complete/{train,valid}.jsonl and data-complete/eval_sentences.json
(held-out sentences, for eval_completion.py).
"""

import ast
import json
import re
import os
import random

SEED = 0xC0FFEE
TAG = "complete"

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------
# 1. Harvested from the rewrite corpus
# --------------------------------------------------------------------------

def harvest_from_rewrite_corpus():
    """Pull realistic sentences out of make_stark_data.py's hand-written pairs.

    Only the SECOND element of each ("before", "after") tuple is taken. The
    first element is deliberately bad writing — typos, comma splices, bloat —
    since that's the rewrite model's *input*. Continuing that text is exactly
    the habit we don't want. Bare strings (docstrings, preset tables, prompt
    boilerplate) are skipped for the same reason.
    """
    path = os.path.join(HERE, "make_stark_data.py")
    if not os.path.exists(path):
        return []
    tree = ast.parse(open(path, encoding="utf-8").read())
    out = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Tuple) or len(node.elts) != 2:
            continue
        good = node.elts[1]
        if not (isinstance(good, ast.Constant) and isinstance(good.value, str)):
            continue
        for part in _split_sentences(good.value):
            if _usable(part):
                out.add(part)
    return sorted(out)


def _split_sentences(text):
    """Break a corpus string into candidate sentences, one per line/terminator."""
    parts = []
    for line in text.split("\n"):
        for chunk in re.split(r"(?<=[.!?])\s+", line):
            chunk = chunk.strip(" -\u2022\t")
            if chunk:
                parts.append(chunk)
    return parts


def _usable(s):
    if not (30 <= len(s) <= 200):
        return False
    if len(s.split()) < 8:
        return False
    # Skip prompt-engineering boilerplate, code, URLs, and template scaffolding.
    bad = ("http", "{", "}", "```", "<", "|", "Resume:", "Email:", "\\")
    if any(b in s for b in bad):
        return False
    # Skip imperative instruction text aimed at an LLM rather than human prose:
    # the prompt-enhance preset's outputs are prompts, not things a person types.
    lead = s.lower().split()[0] if s.split() else ""
    if lead in {"rewrite", "review", "give", "write", "turn", "translate", "draft",
                "brainstorm", "summarize", "summarise", "generate", "create",
                "explain", "list", "convert", "produce", "suggest", "outline"}:
        return False
    # Preset tables and doc bullets ("polish   - fix grammar, ...").
    if "  -" in s or s.count(" - ") > 1:
        return False
    return True


# --------------------------------------------------------------------------
# 2. Authored
# --------------------------------------------------------------------------

AUTHORED = [
    # --- chat / DM -----------------------------------------------------------
    "hey, are you free to hop on a quick call later today?",
    "sorry for the slow reply, I was heads down on the migration all morning",
    "just pushed the fix, can you pull and see if it works on your machine?",
    "no worries at all, take your time with it",
    "did you get a chance to review the PR I sent yesterday?",
    "sounds good to me, I'll put something on the calendar for Thursday",
    "quick heads up, the staging environment is going to be down for about an hour",
    "let me know if you want me to take a look before you ship",
    "I'm running about ten minutes late, be there shortly",
    "that makes sense, let's go with the second option then",
    "can you send me the link to the design doc when you get a chance?",
    "honestly I think the simpler approach is going to age better here",
    "thanks for catching that, I would have missed it completely",
    "we're still waiting on legal to sign off before we can announce",
    "happy to pair on this if it would help move it along faster",
    "I'll be out Friday afternoon but around the rest of the week",
    "just a reminder that the retro is at three this afternoon",
    "I pinged them again this morning but haven't heard back yet",
    "did the deploy finish, or is it still working through the queue?",
    "not urgent, but whenever you get a minute I'd love your take on this",
    "I'm going to grab lunch, back in about forty minutes",
    "that's a much cleaner way of putting it, let's use that",
    "we tried that last quarter and it caused more problems than it solved",
    "can we push our one-on-one to tomorrow? something came up",
    "I think you're right, the extra abstraction isn't earning its keep",
    "the recording should be up on the drive by tomorrow morning",
    "I've been meaning to ask, are you still owning the billing work?",
    "good call, I hadn't considered what happens when the token expires",
    "let's park that for now and come back to it after the launch",
    "I'll write up what we decided and send it round this evening",
    "sorry, that was my fault, I merged before the tests finished",
    "are we still on for the demo, or has that moved again?",
    "I looked through the logs and nothing jumped out unfortunately",
    "it's working on my machine, which usually means I've missed something",
    "thanks for the detailed writeup, that saved me a lot of digging",
    # --- email ---------------------------------------------------------------
    "I just wanted to follow up on the proposal we discussed last week",
    "Thanks for the quick turnaround on the contract review, it's much appreciated",
    "Please let me know if Tuesday at two still works for your team",
    "I've attached the updated deck with the changes you asked for",
    "Apologies for the delay in getting back to you on this",
    "Following up on our conversation, I've outlined the next steps below",
    "I wanted to flag one issue before we move forward with the agreement",
    "Could you confirm whether the invoice was received on your end?",
    "Looking forward to hearing your thoughts when you have a moment",
    "Unfortunately we won't be able to meet the original deadline on this",
    "It was a pleasure speaking with you earlier this week about the role",
    "I'm writing to confirm the details we agreed on during yesterday's call",
    "Please find the revised estimate below for your review and approval",
    "I'd be grateful if you could share this with the wider team",
    "Thank you for your patience while we worked through the backlog",
    "As promised, here is the summary of what we covered in the workshop",
    "I hope you had a good break and are settling back in alright",
    "We've reviewed your application and would like to invite you to the next stage",
    "Just checking in to see whether you had any questions about the quote",
    "I'll be on leave next week, so please direct anything urgent to Sam",
    "Could we schedule thirty minutes early next week to walk through the numbers?",
    "I wanted to give you a heads up before this goes out more widely",
    "Thanks again for making time yesterday, it was genuinely helpful",
    "Please let me know if anything in the attached looks incorrect",
    "I'm afraid we're not able to accommodate that timeline on our side",
    # --- notes / docs --------------------------------------------------------
    "The main risk here is that we're depending on a single upstream provider",
    "Three things came out of the customer interviews we ran this week",
    "The current approach works but doesn't scale past a few thousand users",
    "Next steps are to validate the assumption with a small pilot group",
    "Worth noting that this only affects accounts created before March",
    "The tradeoff is slower writes in exchange for much faster reads",
    "One open question is how we handle accounts that never verified an email",
    "For context, this system was originally built as a temporary workaround",
    "The goal for this quarter is to cut onboarding time roughly in half",
    "Most of the complaints trace back to the same underlying confusion",
    "We agreed to revisit the pricing model once we have more usage data",
    "The proposal below assumes we keep the existing authentication flow",
    "Nobody has clear ownership of this area, which is part of the problem",
    "Two of the five teams have already migrated without any issues",
    "The cost scales linearly with request volume, not with storage",
    "It's worth separating what we know from what we're assuming here",
    "Adoption has been slower than expected, though retention looks healthy",
    "This document captures the decision and the reasoning behind it",
    "The biggest unknown is how the vendor handles a regional outage",
    "We should decide whether this is a product problem or a support problem",
    # --- technical -----------------------------------------------------------
    "The bug only reproduces when the cache is cold and the request times out",
    "I think the root cause is that we're not awaiting the write before returning",
    "We should add a test that covers the empty input case explicitly",
    "The query is slow because it's doing a full scan instead of using the index",
    "This function assumes the list is already sorted, which isn't guaranteed",
    "The migration needs to run before the new code is deployed, not after",
    "Memory usage climbs steadily under load, which points at a leak somewhere",
    "The API returns a two hundred even on failure, so we check the body instead",
    "There's a race between the background refresh and the user-triggered one",
    "Rolling back is safe here because the schema change is additive only",
    "The retry logic is masking an error we should probably be surfacing",
    "We're serializing the same object three times on every request",
    "The timeout is set far too high, so failures take thirty seconds to surface",
    "This only breaks in production because staging has a much smaller dataset",
    "The fix is small but I'd like someone else to sanity check the logic",
    "We should log the request id so these traces are actually correlatable",
    "The dependency was updated last week and the behaviour changed silently",
    "Half the flakiness disappears if we stop sharing state between tests",
    "It's cheaper to recompute this than to keep it in sync across services",
    "The error handling swallows the original exception, which makes this hard to debug",
]

# --------------------------------------------------------------------------
# 3. Templated — the long tail of phrasings
# --------------------------------------------------------------------------

# Slots are grouped into two families that compose coherently. Mixing freely
# across families is what produces nonsense like "worth mentioning that the
# build is failing if that works for everyone" — a statement opener glued to a
# proposal tail. Each family keeps its own openers, bodies, and tails so every
# generated sentence reads like something a person would actually type.

# Family A — proposing something, so the tail can be a condition or caveat.
PROPOSE_OPENERS = [
    "I think we should", "it might make sense to", "any chance we could",
    "would it be crazy to", "I'd rather we", "let's", "we could probably",
    "before we ship I'd like to", "it'd be worth trying to", "can we",
]
PROPOSE_BODIES = [
    "move the review to next week", "push the launch to the end of the month",
    "put this behind a feature flag", "move the migration to a quieter window",
    "get the config into version control", "add these checks to CI",
    "raise the alert threshold a little", "wrap the client in a retry",
    "split this into two smaller changes", "pull the deadline in by a week",
    "drop the reporting feature from scope", "write this up before we forget",
    "loop in the design team early", "cut the meeting down to thirty minutes",
]
PROPOSE_TAILS = [
    "if that works for everyone", "unless someone objects",
    "before we commit to anything", "once the current sprint wraps up",
    "assuming nothing else comes up", "though it's not urgent",
    "and revisit it next quarter", "but I'd want a second opinion first",
]

# Family B — reporting a fact, so the tail explains, qualifies, or consequences.
STATE_OPENERS = [
    "it looks like", "turns out", "I noticed that", "as far as I can tell",
    "the short version is that", "worth mentioning that", "my worry is that",
    "heads up that", "just so you know,", "the annoying part is that",
]
STATE_BODIES = [
    "the build is failing on main", "the rollout is paused for now",
    "the docs are out of date", "the test suite is flaky again",
    "the estimate slipped by about a week", "the API is returning errors",
    "the numbers came back lower than expected", "the client agreed to the terms",
    "onboarding is confusing for new users", "the integration is still blocked",
    "nobody owns this part of the codebase", "the data looks wrong after the import",
    "we're depending on a single provider", "the feedback was mostly positive",
]
STATE_TAILS = [
    "so we should look at it today", "which is going to slow us down",
    "and I don't have a fix yet", "but it's not blocking anything",
    "so we've got a bit of breathing room", "which explains the earlier reports",
    "and it's been that way for a while", "so I'd hold off on shipping",
]


def _decap(phrase):
    """Lowercase a mid-sentence opener, but never the pronoun 'I'."""
    if phrase.startswith("I") and (len(phrase) == 1 or not phrase[1].islower()
                                   or phrase[1] == "'"):
        return phrase
    return phrase[0].lower() + phrase[1:]


def templated(rng, n):
    out = set()
    forms = [
        lambda: f"{rng.choice(PROPOSE_OPENERS)} {rng.choice(PROPOSE_BODIES)} "
                f"{rng.choice(PROPOSE_TAILS)}",
        lambda: f"{rng.choice(STATE_OPENERS)} {rng.choice(STATE_BODIES)}, "
                f"{rng.choice(STATE_TAILS)}",
        # Cross-family only in the one order that stays coherent: a fact, then
        # the proposal it motivates.
        lambda: f"{rng.choice(STATE_OPENERS)} {rng.choice(STATE_BODIES)}, so "
                f"{_decap(rng.choice(PROPOSE_OPENERS))} {rng.choice(PROPOSE_BODIES)}",
    ]
    guard = 0
    while len(out) < n and guard < n * 40:
        guard += 1
        out.add(rng.choice(forms)())
    return sorted(out)


# --------------------------------------------------------------------------
# Pair construction
# --------------------------------------------------------------------------

MIN_PREFIX_WORDS = 2
MIN_CONT_WORDS = 3
MAX_CONT_WORDS = 10
CUTS_PER_SENTENCE = 3


def pairs_for(sentence, rng, cuts=None):
    words = sentence.split()
    lo, hi = MIN_PREFIX_WORDS, len(words) - MIN_CONT_WORDS
    if hi <= lo:
        return []
    k = min(cuts or CUTS_PER_SENTENCE, hi - lo + 1)
    out = []
    for cut in sorted(rng.sample(range(lo, hi + 1), k)):
        prefix = " ".join(words[:cut])
        continuation = " ".join(words[cut:cut + MAX_CONT_WORDS])
        out.append((prefix, " " + continuation))
    return out


def example(user, assistant):
    return {"messages": [
        {"role": "system", "content": TAG},
        {"role": "user", "content": user},
        {"role": "assistant", "content": assistant},
    ]}


def main():
    rng = random.Random(SEED)

    # Real prose is the signal; templates only fill the long tail. Keeping
    # templates to roughly a third — and cutting real sentences more often than
    # templated ones — stops the model learning slot fillers instead of English.
    real = sorted(set(harvest_from_rewrite_corpus()) | set(AUTHORED))
    n_templated = int(len(real) * 0.5)
    generated = [g for g in templated(rng, n_templated) if g not in set(real)]

    rng.shuffle(real)
    rng.shuffle(generated)

    def split(xs, frac=0.08, floor=12):
        n = max(floor, int(len(xs) * frac))
        return xs[:n], xs[n:]

    real_val, real_train = split(real)
    gen_val, gen_train = split(generated)

    REAL_CUTS, GEN_CUTS = 5, 2
    train = ([example(p, c) for s in real_train for p, c in pairs_for(s, rng, REAL_CUTS)]
             + [example(p, c) for s in gen_train for p, c in pairs_for(s, rng, GEN_CUTS)])
    valid = ([example(p, c) for s in real_val for p, c in pairs_for(s, rng, REAL_CUTS)]
             + [example(p, c) for s in gen_val for p, c in pairs_for(s, rng, GEN_CUTS)])
    rng.shuffle(train)
    rng.shuffle(valid)

    # Eval only on real prose — templated sentences flatter the score.
    outdir = os.path.join(HERE, "data-complete")
    os.makedirs(outdir, exist_ok=True)
    for name, rows in (("train.jsonl", train), ("valid.jsonl", valid)):
        with open(os.path.join(outdir, name), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with open(os.path.join(outdir, "eval_sentences.json"), "w", encoding="utf-8") as f:
        json.dump(real_val, f, ensure_ascii=False, indent=1)

    total = len(real) + len(generated)
    print(f"sentences  real={len(real)} (harvested+authored)  templated={len(generated)}  "
          f"-> templated share {100*len(generated)/total:.0f}%")
    print(f"train pairs={len(train)}  valid pairs={len(valid)}")
    print(f"held-out real sentences for eval: {len(real_val)}")
    print(f"-> {outdir}")


if __name__ == "__main__":
    main()
