# Stark — creative brief

A one-pager for whoever is making the LinkedIn material. Everything below is
measured or shipped; nothing here is aspirational. If a number is not in this
document, please ask rather than inventing one.

---

## The product in one line

**Stark is an on-device AI agent that fixes your writing.** Select text
anywhere on your Mac, press ⌘D, and it is rewritten in place.

## The demo moment

This is the whole thing, and it is what any visual should show:

> `i cant beleive how fast this modle runs on my mac`
>
> *⌘D*
>
> **I can't believe how fast this model runs on my Mac.**

No window opened. No copying, no pasting, no tab-switching to a chatbot. The
text was replaced where it sat, in whatever app it was in, in about a second.

## Why it is interesting

Every other writing assistant sends your sentences to somebody's server. Stark
does the thinking on the laptop — a fine-tuned 1.7B model running locally on
Apple silicon. That is the hook, and it carries three claims worth making:

- **Private by construction, not by policy.** There is no account, no API key,
  and no network call. Nothing to leak because nothing leaves.
- **It works everywhere you already type.** Slack, Mail, Notes, a browser text
  box, an IDE. Not a separate app you have to remember to open.
- **It costs nothing to run.** No subscription, no per-token billing.

## Proof points (all measured, all quotable)

| | |
|---|---|
| Ordinary rewrites improved | **5 / 5** |
| Questions preserved as questions | **15 / 16** |
| Sentence-completion first-word accuracy | **45.8%** |
| Completion latency | **~420 ms** mean |
| Rewrite latency | about a second |
| App download | **13 MB** |
| Model, downloaded once | 1.2 GB |
| Runs comfortably in | **8 GB** of RAM |

The 15/16 is worth a sentence of its own if there is room. A rewriting model's
most irritating failure is *answering* you instead of *fixing* you: type
"who is on call this weekend" and a general chatbot explains it cannot see your
rota. Stark was specifically hardened against that, and returns
**"Who's on call this weekend?"**

## The three features

1. **Rewrite** — select anything, press ⌘D, it is fixed in place.
2. **Finish my sentences** — Stark greys in what it thinks comes next as you
   type; Tab accepts it.
3. **Aura** — learns your style from the rewrites you keep, so it sounds more
   like you over time. Stays on the machine.

## Specifications

Apple silicon, macOS 14 or later, about 4 GB free. Ships with its own inference
engine (llama.cpp), so nothing else is installed — no Python, no Homebrew.

Install is one line:

```
curl -fsSL https://raw.githubusercontent.com/YoursSarcastically/stark/main/install.sh | bash
```

---

## Brand

**Logo.** A lightning bolt struck through a ring, drawn as outlines, the bolt
knocking a clean gap out of the ring where they cross. Graphite on white.
Source: `assets/icon.png` (1024px) and `assets/logo.svg`.

**Colour.** Graphite for structure, indigo for anything you can act on. There
is deliberately one accent, so a spot of colour reads as a signal.

| Role | Hex |
|---|---|
| Ink (structure, the mark, body text) | `#45454A` |
| Brand accent (buttons, highlights, the caret) | `#5957D6` |
| Surface | white / `#F5F5F7` |

Please do not introduce a second accent colour, gradient wash, or the orange
this project used to carry.

**Type.** SF Pro, or the closest thing available. Headlines are heavy and
short. Body is regular weight, generous line spacing.

**Voice.** Stark speaks in the first person, confident and dry, and it does not
oversell. Real strings from the product:

> "You write. I'll handle the rest."
> "Suited up."
> "Rewritten, in place. You're welcome."
> "About a second. Give or take."
> "Your words never leave the building."
> "I'll be in the menu bar. Select text, press ⌘D, done."

Do: short declarative sentences, understatement, the occasional wry aside.
Don't: exclamation marks, "revolutionary", "game-changing", em dashes, or
stacking three adjectives where one works.

---

## Assets already available

| File | What it is |
|---|---|
| `assets/icon.png` | The mark, 1024px, graphite on white |
| `assets/logo.svg` | Vector logo |
| `app/Demos/rewrite.gif` | Messy text → ⌘D → clean text. **The money shot.** |
| `app/Demos/predict.gif` | Half a sentence, greyed continuation, Tab accepts |
| `app/Demos/aura.gif` | Kept-rewrite counter climbing |

The GIFs are drawn frame by frame at 2× (520×150 at 1×), in the palette above,
and they can be regenerated at any size with `python tools/make_demos.py` if a
different aspect ratio would help. Product screenshots of the setup flow can be
supplied on request.

## Angles worth considering

1. **The demo, and nothing else.** The rewrite GIF, the one-line description,
   the install command. Lets the product argue for itself.
2. **"Your words never leave the building."** Lead on privacy — the strongest
   differentiator against every cloud writing tool.
3. **The build story.** A fine-tuned 1.7B model, hardened so it stops answering
   questions and starts fixing them, shipped as a 13 MB app. Engineering
   audiences respond to the 15/16 detail.

## Sample post, for tone rather than for copying

> I got tired of pasting my own sentences into a chatbot to get them fixed.
>
> So I built Stark. Select text anywhere on your Mac, press ⌘D, and it is
> rewritten in place. No window, no copying, no account.
>
> It runs a fine-tuned 1.7B model on the laptop itself — about a second per
> rewrite, and nothing you write ever leaves the machine.
>
> Free, open source, one line to install.

## Links

- Repo: https://github.com/YoursSarcastically/stark
- Release: https://github.com/YoursSarcastically/stark/releases/tag/v1.0
- Model: https://huggingface.co/suraj10620/stark-1.7b-gguf
- Built by Suraj Sharma: https://www.linkedin.com/in/surajsharma97/

## Please do not claim

- That it is notarized by Apple, or that it installs with no warning from a
  browser download. It is signed but **not notarized** — the terminal
  installer avoids the Gatekeeper prompt, a hand-downloaded DMG does not.
- Any accuracy figure other than the ones in the table above.
- That it works on Intel Macs, iPhone, or Windows. Apple silicon only.
- That it is a chatbot, or that you can ask it questions. It rewrites text.
  That is the entire product, and the restraint is the point.
