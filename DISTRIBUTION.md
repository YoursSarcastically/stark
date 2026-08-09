# Shipping Stark as a download

`app/make_release.sh` builds a signed, optionally notarized `Stark.dmg`. That solves
packaging. It does **not** yet solve "someone downloads this and it works," because of
two blockers in the current architecture.

## Blocker 1 — the app needs Python

`ServerManager` spawns `python -m mlx_lm server`, reading the interpreter path from
`~/.stark/config.json`. A downloader has no `~/.stark/venv`, no `mlx-lm`, and on a
stock Mac only Python 3.9 with nothing installed. The app launches, the server fails,
and the menu bar says "failed — server exited (code 1)".

**Fix: drop Python and run the model in-process via `mlx-swift`.**

This is exactly what [TabType](https://github.com/nilava/TabType) does — its
`Package.swift` pulls `mlx-swift` + `mlx-swift-lm` and calls `MLXLLM` directly, so its
app bundle is self-contained. Concretely, for Stark:

```swift
// Package.swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.0.0"),
.package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.0"),
```

`StarkClient` then loads the model and streams tokens directly instead of speaking
HTTP to `127.0.0.1:8765`, and `ServerManager` disappears entirely. This also removes
the ~470 ms per-request HTTP round trip, which matters a lot for predictive typing.

Bundling a Python runtime inside the `.app` is the alternative, but it means shipping
several hundred MB of interpreter plus native `mlx` wheels and rewriting the spawn
logic to use the embedded copy. It's strictly worse than going native.

## Blocker 2 — the model is 850 MB

Too big for a DMG people will download twice, and it can't live in git. Do what every
local-model app does: ship the app empty and fetch the weights on first run, with a
progress UI and a resumable download, into `~/Library/Application Support/Stark/`.
`swift-huggingface` handles this if you've already added the MLX packages.

Until then, `config.json` must point at a hand-placed model directory — fine for you,
not for a stranger.

## Gatekeeper

Three tiers, handled automatically by `make_release.sh`:

| What you have | User experience |
|---|---|
| Developer ID + notarization (`NOTARY_PROFILE=…`) | Opens cleanly. The only acceptable option for a public download. |
| Developer ID, no notarization | Blocked on first open; user must right-click → Open. |
| Ad-hoc / self-signed | macOS refuses it. User must run `xattr -dr com.apple.quarantine`. |

Notarization needs a paid Apple Developer account ($99/yr) and a one-time keychain
profile:

```bash
xcrun notarytool store-credentials "stark-notary" \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Then `NOTARY_PROFILE=stark-notary ./app/make_release.sh`.

Note that `setup_signing.sh` ("Stark Dev") is a *local development* identity only — it
keeps macOS from dropping your Accessibility grant on every rebuild. It is not a
Developer ID and cannot be notarized.

## Order of work

1. Port inference to `mlx-swift`, delete `ServerManager` and the Python dependency.
2. First-run model download with progress.
3. Developer ID + notarization.
4. Host the DMG, plus a Sparkle feed if you want auto-updates.

Steps 1 and 2 are the real work; 3 is paperwork and a credit card.
