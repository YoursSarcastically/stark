# Roadmap ⚡

Where Stark is going. No dates — it ships when it works. Have an opinion?
[Open an issue](https://github.com/YoursSarcastically/stark/issues).

## Shipped

- Eight styles, including **Expand** (terse note → fuller message)
- One-press in-place rewrite via a global hotkey, in any app
- **Default Style** picker in the menu bar
- Per-app personas (Slack → friendly+concise, Mail → formal, …)
- Aura: learns from the rewrites you keep, retrains locally on demand
- Long-document chunking (paragraph-by-paragraph, structure preserved)
- Personal dictionary (words the model must never touch)

## Next

- **Signed releases.** A Developer ID–signed, notarized `.app` on GitHub
  Releases — install without building, and the Accessibility grant survives
  updates (ad-hoc builds lose it on every rebuild).
- **Custom styles.** Record your own tag plus a handful of example pairs,
  retrain locally in minutes, get a ninth style that's entirely yours.
- **Fine-tune quality pass.** Longer training pairs so fewer typos slip
  through on long sentences; tighter meaning-preservation on `expand`.
- **Streaming long documents.** Rewrite chunks stream into place with
  progress in the panel, instead of waiting for the whole document.

## Later

- **Low-power mode.** One toggle to swap to the 0.5B model when on battery.
- **Translate & summarize styles** — same one-word-tag interface.
- **Rewrite history.** Opt-in, on-disk log of originals so any rewrite can be
  recovered days later, not just the last one.
- **CLI.** `stark polish < draft.txt` — the same local server, scriptable.
- **Multilingual.** The base model speaks more languages than the fine-tune
  currently allows; teach the styles to follow.

<p align="center"><sub>Roadmaps are drafts. Reality gets a vote. ⚡</sub></p>
