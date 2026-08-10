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

Three tiers, chosen automatically by `make_release.sh` from what is in your
keychain:

| What you have | What the user sees |
|---|---|
| Developer ID + notarization (`NOTARY_PROFILE=…`) | Opens cleanly. The only acceptable option for a public download. |
| Developer ID, no notarization | Blocked on first open; right-click → Open. |
| Ad-hoc / self-signed | macOS refuses it; user must run `xattr -dr com.apple.quarantine`. |

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
2. **A smaller download.** 1.2 GB is a lot for a first impression. Shipping the
   app empty (~55 MB) and fetching the weights on first run is the usual answer,
   at the cost of a download UI and a failure mode on bad networks.
3. **mlx-swift**, eventually. `llama-server` still costs an HTTP hop per
   request. In-process inference would remove it — but it needs Xcode, which is
   the constraint this whole approach was designed to avoid.
