#!/usr/bin/env python3
"""
Balanced, high-volume training pairs for every rewrite preset.

Why this exists: merging completion into the corpus left `complete` at 68% of
all rows and `expand` at 1.6% — down from 11.6% in the original 207-pair set.
Expand degraded to near-uselessness ("the meeting is tuesday" came back as
"The meeting is on Tuesday."). Volume alone wasn't the problem; *balance* was.

The generator builds each pair from one SCENARIO rendered in several registers,
so every preset is trained on the same underlying facts:

    terse    "meeting moved to tuesday"
    neutral  "The meeting has been moved to Tuesday."
    verbose  "The meeting has been moved to Tuesday so the client team can
              attend in person."
    formal   "Please note that the meeting has been moved to Tuesday."
    friendly "Heads up — the meeting's moved to Tuesday!"

From those, each preset's pair falls out by construction:

    expand    terse   -> verbose      concise   verbose -> terse
    formal    neutral -> formal       friendly  neutral -> friendly
    polish    messy   -> neutral      typos     corrupted -> neutral
    bullets   run-on of 3 scenarios -> a bullet per scenario
    prompt    vague ask -> a specific, structured prompt

Deriving every register from one scenario is what keeps the presets consistent
with each other: `concise` is literally the inverse of `expand` on the same
sentence, so the model can't learn contradictory notions of what the text means.
"""

import json
import os
import random
import re

SEED = 0xBA1A9CE
HERE = os.path.dirname(os.path.abspath(__file__))

# Each scenario: terse, neutral, verbose, formal, friendly, bullet.
# Written once, reused across six presets.
SCENARIOS = [
    ("meeting moved to tuesday",
     "The meeting has been moved to Tuesday.",
     "The meeting has been moved to Tuesday so the client team can attend in person rather than dialling in.",
     "Please note that the meeting has been rescheduled to Tuesday.",
     "Heads up — the meeting's moved to Tuesday!",
     "Meeting moved to Tuesday"),
    ("login bug fixed",
     "The login bug is fixed.",
     "The login bug is fixed and the change is already on staging, so it should be safe to test whenever you have a moment.",
     "I am pleased to confirm that the login issue has been resolved.",
     "Good news — the login bug is sorted!",
     "Login bug fixed and on staging"),
    ("need the invoice by friday",
     "We need the invoice by Friday.",
     "We need the invoice by Friday so finance can process it before the end of the quarter.",
     "We would require the invoice by Friday at the latest.",
     "Could we get the invoice by Friday? No rush beyond that.",
     "Invoice needed by Friday"),
    ("api is returning errors",
     "The API is returning errors.",
     "The API is returning intermittent errors under load, roughly one request in twenty, and we haven't isolated the cause yet.",
     "We have observed that the API is currently returning errors.",
     "The API's throwing errors again, unfortunately.",
     "API returning intermittent errors"),
    ("docs are out of date",
     "The documentation is out of date.",
     "The documentation is out of date in several places, particularly the setup guide, which still references the old configuration format.",
     "Please be advised that the documentation is no longer current.",
     "The docs are pretty stale at this point!",
     "Documentation out of date, especially setup"),
    ("cant make standup tomorrow",
     "I can't make standup tomorrow.",
     "I can't make standup tomorrow because of a conflicting appointment, but I'll post my update in the channel beforehand.",
     "Unfortunately I will be unable to attend tomorrow's standup.",
     "Can't make standup tomorrow, sorry!",
     "Missing standup tomorrow, will post update"),
    ("hiring two engineers",
     "We are hiring two engineers.",
     "We are hiring two engineers this quarter, both on the platform team, with a focus on backend and reliability work.",
     "We intend to recruit two additional engineers this quarter.",
     "We're bringing on two more engineers!",
     "Hiring two platform engineers this quarter"),
    ("pricing page ships next week",
     "The new pricing page ships next week.",
     "The new pricing page ships next week, assuming the copy review lands on time and legal have no further comments.",
     "The new pricing page is scheduled for release next week.",
     "New pricing page goes live next week!",
     "Pricing page ships next week"),
    ("server was down for an hour",
     "The server was down for an hour.",
     "The server was down for about an hour this morning after a failed deploy, and we've since rolled back and added a health check.",
     "The server experienced approximately one hour of downtime this morning.",
     "We had about an hour of downtime this morning — all sorted now.",
     "One hour of downtime after a failed deploy"),
    ("customer wants a refund",
     "The customer is requesting a refund.",
     "The customer is requesting a refund because the plan auto-renewed after they believed they had cancelled it.",
     "The customer has submitted a request for a refund.",
     "This customer's asking for a refund.",
     "Customer requesting refund after auto-renewal"),
    ("tests are flaky",
     "The test suite is flaky.",
     "The test suite is flaky, failing perhaps one run in five, and it's almost always the same three integration tests sharing state.",
     "The test suite is currently exhibiting intermittent failures.",
     "The tests are flaky again!",
     "Test suite flaky — three integration tests share state"),
    ("need approval on the budget",
     "We need approval on the budget.",
     "We need approval on the budget before the end of the month, otherwise the vendor contract lapses and we start again at a higher rate.",
     "We require your approval of the budget at your earliest convenience.",
     "Any chance you could approve the budget soon?",
     "Budget approval needed before month end"),
    ("onboarding takes too long",
     "Onboarding takes too long.",
     "Onboarding takes too long — around three days from signup to first useful action — and most of that is waiting on manual account provisioning.",
     "The onboarding process is currently longer than we would like.",
     "Onboarding's way too slow right now.",
     "Onboarding takes ~3 days, mostly manual provisioning"),
    ("migration finished over the weekend",
     "The migration finished over the weekend.",
     "The migration finished over the weekend with no data loss, and the old cluster is scheduled for decommissioning on Friday.",
     "The migration was completed over the weekend as planned.",
     "Migration's done — went smoothly over the weekend!",
     "Migration complete, old cluster off Friday"),
    ("conference talk accepted",
     "Our conference talk was accepted.",
     "Our conference talk was accepted for the September track, which gives us about six weeks to put the material together.",
     "I am delighted to report that our conference submission has been accepted.",
     "Our talk got accepted!",
     "Talk accepted for the September track"),
    ("support tickets are up",
     "Support tickets are up this month.",
     "Support tickets are up roughly forty percent this month, and the majority trace back to the same billing confusion after the plan change.",
     "We have observed a notable increase in support tickets this month.",
     "Support tickets have really spiked this month.",
     "Tickets up ~40%, mostly billing confusion"),
    ("contract needs a signature",
     "The contract needs your signature.",
     "The contract needs your signature before we can start work, and the countersigned copy should go back to their legal team the same day.",
     "The contract requires your signature at your earliest convenience.",
     "Just needs your signature and we're good to go!",
     "Contract awaiting signature"),
    ("laptop order delayed",
     "The laptop order is delayed.",
     "The laptop order is delayed by about two weeks because the supplier is out of stock on that configuration.",
     "Regrettably, the laptop order has been delayed.",
     "Laptops are running about two weeks late.",
     "Laptop order delayed ~2 weeks, supplier stock"),
    ("dashboard is ready for review",
     "The dashboard is ready for review.",
     "The dashboard is ready for review — the filters and export are working, though the date picker still needs polish.",
     "The dashboard is now available for your review.",
     "Dashboard's ready whenever you want to take a look!",
     "Dashboard ready — date picker still rough"),
    ("we lost the deal",
     "We did not win the deal.",
     "We did not win the deal; they went with a cheaper competitor, though they left the door open for a conversation next year.",
     "Unfortunately we were unsuccessful in securing the contract.",
     "We didn't get it, sadly — they went cheaper.",
     "Deal lost on price, revisit next year"),
]

# Prompt-enhance is a different shape: a vague ask becomes a specific brief.
PROMPT_PAIRS = [
    ("write something about our new product",
     "Write a 200-word announcement for our new product. Open with the problem it solves, give three concrete benefits, name the target user, and close with a single clear call to action. Plain language, no superlatives."),
    ("help me with my resume",
     "Review the resume below and suggest improvements. Focus on quantifying achievements, strengthening verbs, and cutting filler. Quote the specific line for each suggestion and give a before/after rewrite. Do not invent accomplishments."),
    ("write tests for this function",
     "Write unit tests for the function below. Cover the happy path, empty and null inputs, boundary values, and one failure mode. Use the project's existing test framework and naming style. Explain what each test protects against."),
    ("make a plan for the launch",
     "Draft a launch plan for the next six weeks. Include milestones with owners and dates, the three biggest risks with mitigations, a go/no-go checklist, and what we measure in the first week after launch."),
    ("summarize this meeting",
     "Summarise the meeting notes below into: decisions made, action items with owners and due dates, and open questions. Keep it under 200 words and omit discussion that led nowhere."),
    ("write a job description",
     "Write a job description for the role below. Include a two-sentence team summary, five day-to-day responsibilities, must-have versus nice-to-have skills kept separate, and the interview process. Avoid clichés like 'rockstar' and 'fast-paced'."),
    ("explain this code",
     "Explain the code below to someone competent but unfamiliar with this codebase. Cover what it does, why it is structured this way, the non-obvious edge cases it handles, and anything that would surprise a reader."),
    ("give me interview questions",
     "Give me eight interview questions for the role below: three on technical depth, two on system design, two on collaboration, and one on mentoring. For each, note in one line what a strong answer contains."),
    ("write a follow up email",
     "Write a follow-up email to a prospect who went quiet after a demo two weeks ago. Under 120 words, reference something specific from the demo, offer one concrete next step, and give them an easy way to decline."),
    ("help me apologize to a customer",
     "Draft an apology to a customer affected by an outage. Acknowledge the specific impact, state what went wrong without jargon, say what we have changed to prevent recurrence, and offer a concrete remedy. No defensiveness."),
]

# Typo corruption, so `typos` gets volume from the same neutral sentences.
KEYBOARD_NEIGHBOURS = {
    "a": "sq", "e": "wr", "i": "ou", "o": "ip", "u": "yi", "t": "ry",
    "n": "bm", "s": "ad", "r": "et", "l": "k", "c": "vx", "d": "sf",
}
COMMON_MISSPELLINGS = {
    "the": "teh", "and": "adn", "because": "becuase", "receive": "recieve",
    "separate": "seperate", "definitely": "definately", "necessary": "neccessary",
    "believe": "beleive", "which": "wich", "their": "thier", "would": "wuold",
    "there": "ther", "before": "befor", "should": "shuold", "about": "abuot",
    "meeting": "meetng", "documentation": "documentaion", "environment": "enviroment",
}


def corrupt(sentence, rng):
    """Introduce a handful of realistic typos without destroying readability."""
    words = sentence.split()
    n = max(1, len(words) // 6)
    idxs = rng.sample(range(len(words)), min(n, len(words)))
    for i in idxs:
        w = words[i]
        bare = re.sub(r"\W", "", w).lower()
        if bare in COMMON_MISSPELLINGS:
            words[i] = w.lower().replace(bare, COMMON_MISSPELLINGS[bare])
            continue
        if len(bare) < 4:
            continue
        mode = rng.choice(["swap", "drop", "neighbour"])
        chars = list(w)
        j = rng.randrange(1, len(chars) - 1)
        if mode == "swap":
            chars[j], chars[j - 1] = chars[j - 1], chars[j]
        elif mode == "drop":
            del chars[j]
        else:
            c = chars[j].lower()
            if c in KEYBOARD_NEIGHBOURS:
                chars[j] = rng.choice(KEYBOARD_NEIGHBOURS[c])
        words[i] = "".join(chars)
    return " ".join(words)


def messy(sentence, rng):
    """Un-polish a clean sentence: filler, lowercase, dropped punctuation."""
    s = sentence
    fillers = ["just ", "basically ", "kind of ", "i think ", "honestly ", "so "]
    s = s[0].lower() + s[1:]
    if rng.random() < 0.7:
        s = rng.choice(fillers) + s
    if rng.random() < 0.5:
        s = s.rstrip(".")
    if rng.random() < 0.4:
        s = s.replace(" is ", " is kinda ")
    if rng.random() < 0.3:
        s = s.replace("'", "")
    return s


def example(tag, user, assistant):
    return {"messages": [
        {"role": "system", "content": tag},
        {"role": "user", "content": user},
        {"role": "assistant", "content": assistant},
    ]}


def perturb(text, rng):
    """Vary the INPUT side without changing meaning.

    expand/concise/formal/friendly are deterministic maps — one scenario gives
    exactly one pair, and dedup then leaves ~20 examples per preset. Real users
    don't type the canonical phrasing, so perturbing the input both multiplies
    the data and teaches the preset to fire on messy input rather than only on
    the one sentence it was shown.
    """
    s = text
    roll = rng.random()
    if roll < 0.30:
        s = s[0].lower() + s[1:]
    elif roll < 0.45:
        s = s.rstrip(".")
    elif roll < 0.60:
        s = s[0].lower() + s[1:].rstrip(".")
    elif roll < 0.72:
        s = rng.choice(["hey ", "so ", "fyi ", "quick one: "]) + s[0].lower() + s[1:]
    elif roll < 0.85:
        s = corrupt(s, rng)
    return s


def build(rng, variants_per_scenario=14):
    rows = []
    for terse, neutral, verbose, formal, friendly, bullet in SCENARIOS:
        for _ in range(variants_per_scenario):
            rows.append(example("expand", perturb(terse, rng), verbose))
            rows.append(example("concise", perturb(verbose, rng), neutral))
            rows.append(example("formal", perturb(neutral, rng), formal))
            rows.append(example("friendly", perturb(neutral, rng), friendly))
            rows.append(example("polish", messy(neutral, rng), neutral))
            rows.append(example("typos", corrupt(neutral, rng), neutral))

    # Bullets: three scenarios strung into one run-on, then broken apart.
    for _ in range(len(SCENARIOS) * variants_per_scenario):
        picks = rng.sample(SCENARIOS, 3)
        run_on = ", ".join(p[0] for p in picks)
        listed = "\n".join("- " + p[5] for p in picks)
        rows.append(example("bullets", run_on, listed))

    for _ in range(variants_per_scenario * 3):
        for vague, precise in PROMPT_PAIRS:
            rows.append(example("prompt", perturb(vague, rng), precise))

    # Dedup: the same messy()/corrupt() draw can repeat.
    seen, unique = set(), []
    for r in rows:
        key = (r["messages"][0]["content"], r["messages"][1]["content"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(r)
    return unique


def main():
    rng = random.Random(SEED)
    rows = build(rng)
    rng.shuffle(rows)
    n_val = max(20, int(len(rows) * 0.08))
    valid, train = rows[:n_val], rows[n_val:]

    outdir = os.path.join(HERE, "data-presets")
    os.makedirs(outdir, exist_ok=True)
    for name, data in (("train.jsonl", train), ("valid.jsonl", valid)):
        with open(os.path.join(outdir, name), "w", encoding="utf-8") as f:
            for r in data:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    counts = {}
    for r in rows:
        t = r["messages"][0]["content"]
        counts[t] = counts.get(t, 0) + 1
    print(f"preset pairs: {len(rows)} (train {len(train)} / valid {len(valid)})")
    print("per preset:", json.dumps(counts, sort_keys=True))
    print(f"-> {outdir}")


if __name__ == "__main__":
    main()
