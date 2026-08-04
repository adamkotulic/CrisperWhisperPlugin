# CrisperWhisper 2.0 for TypeWhisper

An experimental, local CrisperWhisper 2.0 transcription plugin for TypeWhisper
on Apple Silicon Macs.

It provides four selectable model sizes, separate Verbatim and Intended modes,
and TypeWhisper's Auto language option. Audio stays on the Mac.

## Install

Requirements: macOS 14 or newer, Apple Silicon, TypeWhisper, and a full Xcode
installation.

```bash
git clone https://github.com/adamkotulic/CrisperWhisperPlugin.git
cd CrisperWhisperPlugin
./install.sh --model large
```

That single script:

1. creates an isolated Python 3.12 runtime;
2. installs CrisperWhisper 2.0.1 and downloads the selected model;
3. builds and ad-hoc signs the Release plugin bundle;
4. backs up any older plugin installation;
5. installs the new bundle and restarts TypeWhisper.

Nothing is installed into the system Python.

To start with a smaller download:

```bash
./install.sh --model small
```

To defer the model download until first use:

```bash
./install.sh --no-download
```

After installation, select **CrisperWhisper 2.0** in TypeWhisper, choose one of
the eight model/mode entries, and leave language on **Auto** unless you want to
force a specific language.

## Model choices

- Large — Verbatim / Intended
- Turbo — Verbatim / Intended
- Medium — Verbatim / Intended
- Small — Verbatim / Intended

Changing only Verbatim/Intended mode reuses the loaded model. Changing model
size unloads the old model and loads the selected one.

## Repair or update

From an updated checkout, rebuild and reinstall while keeping the runtime and
downloaded models:

```bash
git pull --ff-only
./install.sh --repair
```

Runtime-only health check:

```bash
./verify_runtime.sh
```

Worker diagnostics are written to:

```text
~/Library/Application Support/TypeWhisper/CrisperWhisperRuntime/worker.log
```

## Uninstall

The default uninstall is recoverable: it moves the plugin bundle to the Trash
and keeps the private runtime/model cache.

```bash
./uninstall.sh
```

To also move the runtime and downloaded models to the Trash:

```bash
./uninstall.sh --purge-runtime
```

## Runtime behavior and limitations

- Python and the selected model stay alive between transcriptions.
- Inference requests are serialized to prevent concurrent large-model loads.
- Cancellation, timeouts, worker restarts, protected temporary files, and a
  rotating log are supported.
- Apple MPS with float16 is attempted first. An MPS-specific failure triggers
  one recoverable retry on CPU with float32.
- Auto language detection runs on the already-loaded Whisper model.
- Translation, streaming, dual transcript output, and exported word-level
  timestamps are intentionally not advertised.
- Model downloads, deletion, and storage are managed by the private runtime,
  not TypeWhisper's built-in model manager.

The macOS worker uses the Transformers backend. CrisperWhisper's CTranslate2
fork does not currently provide a macOS wheel, so the worker supplies a narrow
compatibility shim only for the package's pure-Python loop-repair helpers.

## Licensing

This plugin is GPL-3.0 because it links against the GPL-3.0
TypeWhisperPluginSDK. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The repository and built bundle do **not** contain model weights. The standard
CrisperWhisper model weights use Nyra's non-commercial research terms.
Commercial use requires a separate commercial model license from Nyra.

## Validation

Validated on macOS on 2026-08-04 with Xcode 26.6, TypeWhisper 1.6.0,
TypeWhisperPluginSDK 1.0.0, Python 3.12.13, CrisperWhisper 2.0.1, and PyTorch
2.13.0. The arm64 Release bundle builds, receives an ad-hoc signature, passes
strict signature verification, and loads in TypeWhisper with all eight model
and mode choices.

An end-to-end synthetic English speech test loaded the Large model on Apple MPS,
used Auto language detection, and returned a non-empty transcript. This remains
an experimental community integration rather than an official TypeWhisper
engine.
