# Shipping Stark

`app/make_release.sh` builds `Stark.dmg`. The app inside it is **self-contained**:
a bundled inference engine and the model weights, no Python, no downloads, no
configuration. Drag it to Applications and it works offline.

That was not true until recently. The app used to spawn `python -m mlx_lm
server`, so a downloader got "server exited (code 1)" unless they happened to
have a Python with mlx-lm installed. Two changes fixed it.

## The engine ships with the app

`llama.cpp`'s prebuilt `llama-server` (~23 MB, Metal-accelerated) lives in
`Stark.app/Contents/Resources/llama/`. Its `LC_RPATH` is `@loader_path`, so the
binary and its dylibs resolve each other simply by sharing a directory.

**Prebuilt is the point.** Building `llama.cpp` — or `mlx-swift` — from source
requires the Metal compiler, which ships with Xcode and not with Command Line
Tools. Using release binaries means Stark builds and ships without anyone
installing Xcode.

Fetch them once with the snippet in `vendor/README.md`.

## The weights ship with the app

`stark-1.7b-Q5_K_M.gguf` (1.2 GB) sits in `Contents/Resources/model/`.
`Config.modelPath` falls back to it when `~/.stark/config.json` names nothing —
which is the case for every downloader, since they have no config file at all.

Q5_K_M rather than Q4_K_M: Q4 cost about 140 MB less but measurably degraded
`expand`, and scored 15/16 rather than matching the MLX build on the rewrite
regression suite.

Build a smaller app that expects an external model with
`STARK_MODEL=/dev/null ./make_app.sh`.

## Regenerating the GGUF

The published MLX model is 4-bit and GGUF cannot read MLX quantisation, so the
conversion starts from full precision:

```bash
# 1. Fuse the adapter onto the FP16 base (not the 4-bit one)
python -m mlx_lm fuse --model Qwen/Qwen3-1.7B \
    --adapter-path model/adapters-unified-1.7b --save-path model/stark-1.7b-fp16

# 2. HF -> GGUF (needs vendor/llama.cpp-src and torch)
python vendor/llama.cpp-src/convert_hf_to_gguf.py model/stark-1.7b-fp16 \
    --outfile model/stark-1.7b-f16.gguf --outtype f16

# 3. Quantise
./vendor/llama-b10333/llama-quantize model/stark-1.7b-f16.gguf \
    model/stark-1.7b-Q5_K_M.gguf Q5_K_M
```

Then re-run both eval harnesses against `llama-server` before shipping.

## Gatekeeper

**Send people the install line, not the DMG.**

```bash
curl -fsSL https://raw.githubusercontent.com/YoursSarcastically/stark/main/install.sh | bash
```

`install.sh` clears the quarantine flag as part of installing, so nobody sees
a warning at all. A DMG handed over directly — AirDrop, email, a download link
— arrives quarantined, and the app is signed with a self-signed certificate
that exists only on the machine that built it. On anyone else's Mac that
authority is unknown and `spctl` rejects it outright.

Three tiers, chosen automatically by `make_release.sh` from what is in your
keychain:

| What you have | What the user sees |
|---|---|
| Developer ID + notarization (`NOTARY_PROFILE=…`) | Opens cleanly. The only option that works for a plain download link. |
| Developer ID, no notarization | Blocked on first open; System Settings → Privacy & Security → Open Anyway. |
| Ad-hoc / self-signed (today) | Refused. Either install via `install.sh`, or see below. |

### If someone already has the DMG

Control-click → Open no longer works: macOS 15 removed that bypass. The two
paths that do:

```bash
xattr -dr com.apple.quarantine /Applications/Stark.app
```

or, without a terminal: try to open Stark, then **System Settings → Privacy &
Security**, scroll to the message about Stark, and click **Open Anyway**.

Neither is something you can reasonably ask a stranger to do, which is why
notarization is the only real answer for public distribution.

Notarization needs a paid Apple Developer account and a one-time keychain
profile:

```bash
xcrun notarytool store-credentials "stark-notary" \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Then `NOTARY_PROFILE=stark-notary ./app/make_release.sh`.

`setup_signing.sh` ("Stark Dev") is a *local development* identity only — it
stops macOS dropping your Accessibility grant on every rebuild. It is not a
Developer ID and cannot be notarized.

## What is left

1. **Notarization.** The only thing between the current DMG and a link anyone
   can click. Needs the $99/yr account.
3. **mlx-swift**, eventually. `llama-server` still costs an HTTP hop per
   request. In-process inference would remove it — but it needs Xcode, which is
   the constraint this whole approach was designed to avoid.
