# Susurro — your amanuensis

Push-to-talk dictation for macOS. Hold a key anywhere, speak, release — your
words are typed into whatever app has focus. Transcription runs entirely on
your Mac via [whisper.cpp](https://github.com/ggerganov/whisper.cpp); nothing
leaves your machine.

- Hold **Right Option** (configurable) to record; release to transcribe & type
- Live waveform overlay while recording
- Spoken punctuation: "comma", "period", "quote … end quote", "new line" —
  fully configurable via a human-editable `rules.json` (plus jargon fix-ups
  and regex rules), live-reloaded
- Whisper model manager: download/switch tiny → large-v3-turbo from the menu
- Optional on-device AI grammar cleanup (Apple Intelligence, macOS 26+)
- One process, no daemons; starts at login if you want

## Requirements

- Apple Silicon Mac, macOS 15+ (AI Cleanup requires macOS 26 + Apple Intelligence)
- ~600 MB free RAM while running (default small.en model)

## Installing (prebuilt zip)

Download the latest zip from [Releases](https://github.com/mtwomey/susurro/releases).

1. Unzip and drag **Susurro.app** to `/Applications`
2. Launch it. macOS will refuse ("Apple could not verify…") because this build
   isn't notarized: open **System Settings → Privacy & Security**, scroll down,
   click **Open Anyway**, then confirm
3. Grant the two permissions when prompted:
   - **Microphone** (recording)
   - **Accessibility** (the hold-key listener and typing) — System Settings →
     Privacy & Security → Accessibility → enable Susurro, then quit & relaunch
4. On first run Susurro automatically downloads the default **small.en** model
   (~466 MB, one time) — a banner appears when the download starts and a
   notification when dictation is ready. Other sizes are available under the
   **Model** menu.
5. Hold **Right Option**, speak, release. Done.

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
- **Models**: menu → **Model**; downloads go to
  `~/Library/Application Support/Susurro/models`
- **Smart Spacing** (off by default): menu → **Smart Spacing**. When on,
  dictating again right after Susurro typed a `.`, `!`, or `?` adds a
  leading space so back-to-back dictations don't run together. Tracked by
  Susurro itself (not a field read), so it resets if you switch apps in
  between.

## Notes

- The orange dot and mic pill in the menu bar while recording are macOS
  privacy indicators — every legitimate app that records shows them
- Password fields block synthetic typing (macOS secure input); Susurro detects
  this and copies the transcript to the clipboard so it isn't lost. Copying to
  the clipboard on every dictation is available as a menu toggle (off by
  default — your clipboard is yours)

## For developers

- `ARCHITECTURE.md` — as-built structure, code map, dataflow, hard-won constraints
- `DEVELOPMENT.md` — machine setup (incl. signing identity), make targets,
  testing, debugging, release process
- `PLAN.md` — historical design doc: decisions, spike data, investigations,
  rejected alternatives, v2 parking lot
- `CHECKLIST.md` — manual release acceptance checklist
