# vendor/

Prebuilt `llama.cpp` binaries, copied into `Stark.app/Contents/Resources/llama/`
by `app/make_app.sh`. Not checked in — they are release artifacts, ~26 MB.

Fetch them:

```bash
cd vendor
curl -sL -o llama.tar.gz \
  https://github.com/ggml-org/llama.cpp/releases/download/b10333/llama-b10333-bin-macos-arm64.tar.gz
tar xzf llama.tar.gz && rm llama.tar.gz
```

Prebuilt matters: building `llama.cpp` from source needs the Metal compiler,
which ships with Xcode and not with Command Line Tools. Using the release
binaries means Stark builds — and ships — without anyone installing Xcode.

`llama.cpp-src/` is only needed to regenerate the GGUF weights
(`convert_hf_to_gguf.py`); the app never touches it.
