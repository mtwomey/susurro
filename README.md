# Susurro — your amanuensis

Push-to-talk dictation for macOS. Hold a key anywhere, speak, release — your
words are typed into whatever app has focus. Transcription runs entirely on
your Mac via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) or, optionally,
NVIDIA's [Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
through [FluidAudio](https://github.com/FluidInference/FluidAudio); nothing
leaves your machine.

- Hold **Right Option** (configurable) to record; release to transcribe & type
- Hands-free for longer passages: while holding, tap **Right Command** (the
  latch key; never the push-to-talk key), let go and keep talking — text is
  typed at each pause. Tap push-to-talk to stop, Esc to discard. Stops by
  itself after 60 s without speech, 2 hours, or an app switch
- Live waveform overlay while recording
- Spoken punctuation: "comma", "period", "quote … end quote", "new line" —
  fully configurable via a human-editable `rules.json` (plus jargon fix-ups
  and regex rules), live-reloaded
- Model manager: download/switch Whisper models (tiny → large-v3-turbo) or
  NVIDIA Parakeet v2 (English, most accurate) from the menu
- Optional on-device AI grammar cleanup (Apple Intelligence, macOS 26+)
- One process, no daemons; starts at login if you want

## Requirements

- Apple Silicon Mac, macOS 15+ (AI Cleanup requires macOS 26 + Apple Intelligence)
- ~600 MB free RAM while running (default small.en model)

## Installing

### Option A — Homebrew (recommended)

```bash
brew install --cask mtwomey/susurro/susurro
```

```bash
brew upgrade --cask susurro
```

If Homebrew says the tap isn't trusted, run `brew trust --cask mtwomey/susurro/susurro`.

### Option B — Manual zip

Download the latest zip from [Releases](https://github.com/mtwomey/susurro/releases),
then unzip and drag **Susurro.app** to `~/Applications`.

## First run (either install method)

1. Grant the two permissions when prompted:
   - **Microphone** (recording)
   - **Accessibility** (the hold-key listener and typing) — System Settings →
     Privacy & Security → Accessibility → enable Susurro, then quit & relaunch
2. On first run Susurro automatically downloads the default **small.en** model
   (~466 MB, one time) — a banner appears when the download starts and a
   notification when dictation is ready. Other sizes are available under the
   **Model** menu.
3. Hold **Right Option**, speak, release. Done.

Optional: menu → **Start at Login**.

## Building from source

```bash
git clone --recurse-submodules <repo-url> && cd susurro
make whisper   # build vendored whisper.cpp (once)
make run       # build, bundle, launch
make test      # unit + golden tests
make dist      # distributable zip in build/
```

Signing uses a local self-signed "Susurro Dev" identity if present (keeps
macOS permission grants stable across rebuilds); create one in Keychain
Access, or edit `SIGN_ID` in the Makefile.

## Configuration

- **Rules** (spoken punctuation, jargon substitutions, regex): menu →
  **Edit Rules…** — changes apply on your next dictation
- **Push-to-talk key**: menu → **Push-to-Talk Key**
- **Hands-free latch key**: menu → **Hands-Free Latch Key** (offers only the
  keys that aren't push-to-talk)
- **Models**: menu → **Model**; downloads go to
  `~/Library/Application Support/Susurro/models`. Picking a model you
  haven't downloaded starts the download (progress shows in the menu) and
  switches to it when it finishes; picking a downloaded one switches to it
  right away.
- **Smart Spacing** (off by default): menu → **Smart Spacing**. When on,
  dictating again right after Susurro typed something adds a leading space
  (unless one's already there), so back-to-back dictations don't run
  together. Tracked by Susurro itself (not a field read), so it resets if
  you switch apps in between.

## Model options

The **Model** menu groups models by engine. Every entry shows its download
size and a short note.

| Model | Engine | Size | Notes |
|---|---|---|---|
| tiny.en | Whisper | ~75 MB | fastest, roughest |
| base.en | Whisper | ~142 MB | fast, light |
| **small.en** | Whisper | ~466 MB | **default**: best balance |
| medium.en | Whisper | ~1.5 GB | high accuracy, slower |
| large-v3-turbo | Whisper | ~1.6 GB | most accurate Whisper, multilingual |
| parakeet-tdt-v2 | NVIDIA Parakeet | ~443 MB | English only, most accurate, Apple Silicon only |

Parakeet is optional; Susurro never switches you to it. On the project's test
clips it made about a fifth as many word errors as small.en (2.4% vs 11.4%)
and transcribed roughly 3.5× faster. It formats numbers, times and currency
itself, and spoken punctuation ("comma", "new line", …) works the same way as
with Whisper. The first load after downloading takes ~20 s while macOS
compiles the model; later loads are quick. Details are in
[`docs/PARAKEET_PLAN.md`](docs/PARAKEET_PLAN.md).

## Notes

- The orange dot and mic pill in the menu bar while recording are macOS
  privacy indicators — every legitimate app that records shows them
- Password fields block synthetic typing (macOS secure input); Susurro detects
  this and copies the transcript to the clipboard so it isn't lost. Copying to
  the clipboard on every dictation is available as a menu toggle (off by
  default — your clipboard is yours)

## Attribution

- Speech recognition by [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
  (MIT) with OpenAI Whisper models (MIT).
- Parakeet TDT 0.6B v2 speech model © NVIDIA, licensed under
  [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). Core ML conversion
  by [FluidInference](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml);
  run via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0).
  The model is downloaded from Hugging Face on request and is not bundled
  with Susurro. The same credit appears in **About Susurro**.

## For developers

All developer docs live in [`docs/`](docs):

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — as-built structure, code map, dataflow, hard-won constraints
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — machine setup (incl. signing identity), make targets,
  testing, debugging, release process
- [`docs/PLAN.md`](docs/PLAN.md) — historical design doc: decisions, spike data, investigations,
  rejected alternatives, v2 parking lot
- [`docs/SMART_SPACING_PLAN.md`](docs/SMART_SPACING_PLAN.md) — Smart Spacing design doc: why an
  Accessibility-based approach was rejected in favor of self-tracking
- [`docs/VOCABULARY_PROMPT_PLAN.md`](docs/VOCABULARY_PROMPT_PLAN.md) — proposed custom-vocabulary
  feature (whisper initial-prompt biasing), with spike results
- [`docs/PARAKEET_PLAN.md`](docs/PARAKEET_PLAN.md) — NVIDIA Parakeet TDT v2 engine: feasibility spike,
  catalog/download design, post-processing changes, whisper vs Parakeet A/B results
- [`docs/CHECKLIST.md`](docs/CHECKLIST.md) — manual release acceptance checklist
- [`docs/releasing.md`](docs/releasing.md) — step-by-step release process including Homebrew tap update
