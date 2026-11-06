# Susurro — Architecture (as built)

This file describes what actually exists as of **0.2.0** (push-to-talk,
hands-free latching with pause-cut chunks and joins, the pre-insert
text-handling stage, and the whisper.cpp + Parakeet engines).

Finished design docs and plans live in `docs/history/` (start with
`history/PLAN.md` for *why* decisions were made, including
investigated-and-rejected alternatives). Live design notes: 
`TEXT_HANDLING_FINDINGS.md` (text handling) and `HANDSFREE_JOINS.md`
(hands-free joins). Code removed in the R0 housekeeping (the unused
`HALAudioRecorder`/`SCKAudioRecorder` capture alternatives and the
`parakeet-spike` harness) lives on in git history before the
`chore/r0-housekeeping` merge.

## Overview

Single-process macOS menu bar app (Swift 6, strict concurrency, SwiftPM — no
Xcode project). Hold a key → record mic to memory → transcribe in-process with
the active engine (whisper.cpp, or NVIDIA Parakeet TDT v2 via FluidAudio/Core ML
on Apple Silicon) → post-process text → pre-insert text handling (spacing and
case from what precedes the cursor) → type into the focused app via CGEvents.
Or latch the recording hands-free: it is cut at natural pauses and each piece
is transcribed and typed while the user keeps talking.
No daemons, temp files, or network dependency after model download (the only
socket is the optional, local Emacs-server bridge).

## Targets & code map

```
Package.swift               SPM manifest; whisper linker flags defined once, shared;
                            whisper -I/-L paths are absolute (#filePath root) and
                            mirrored into swiftSettings via -Xcc (needed once a
                            package dependency is present); FluidAudio pinned
                            exact 0.9.1
Sources/
  CWhisper/                 C shim exposing vendor whisper.h to Swift (empty .c + header)
  SusurroCore/              Library shared by app, CLI, tests
    TranscriptionEngine.swift Engine protocol (warm load, 16 kHz in, serialized
                              transcribe → trimmed text) + TranscriptionEngines.load
                              factory; app and CLI depend on these only
    WhisperEngine.swift       whisper.cpp C API wrapper (TranscriptionEngine); model
                              loaded once, stays warm; transcribe() internally
                              serialized (ctx not reentrant)
    ParakeetEngine.swift      Parakeet TDT v2 via FluidAudio (TranscriptionEngine):
                              AsrModels.load(from: Susurro models dir) — never
                              downloads (checks modelsExist first); AsrManager is
                              non-Sendable, so NSLock + detached task/semaphore bridge
                              async → sync; pads <1 s buffers to 16,000 samples
    AudioRecorder.swift       PRODUCTION capture: AVAudioEngine input tap → 16kHz mono
                              Float32 in RAM; peak-level callback; config-change
                              (mic unplugged) interruption callback
                              takeAvailable() drains new samples while recording
                              (hands-free pump)
    AudioFileLoader.swift     any audio file → 16kHz mono Float32 (used by CLI/tests)
    AudioResampler.swift      shared mono resample helper
    ModelManager.swift        model catalog: entries carry an EngineKind (5 whisper ggml
                              files + Parakeet TDT v2 Core ML directory); HuggingFace
                              download with progress (FileDownloader: URLSession delegate
                              wrapped in async/await; directory models are fetched
                              file-by-file from the HF tree listing into a staging dir,
                              then renamed into place), active-model selection,
                              legacy-path seed
    PostProcessor.swift       verbal punctuation pipeline; loads rules fresh from user
                              rules.json EVERY call (= live reload); falls back to
                              DefaultRules on missing/corrupt file. Engine-agnostic,
                              but tolerant of Parakeet's own punctuation: strips
                              ,.?!;: glued after a trigger word, lowercases a
                              capitalised word after a mid-sentence trigger, and
                              quote triggers absorb adjacent quote marks
    DefaultRules.swift        default rules.json EMBEDDED as a Swift string. Deliberate:
                              SPM Bundle.module resources DO NOT WORK in hand-assembled
                              .app bundles (crashed 0.1.0 on all non-dev machines)
    TranscriptFilter.swift    strips whisper hallucination tokens ([BLANK_AUDIO] etc.);
                              engine-aware — the [...] strip is whisper-only, so
                              dictated brackets survive on Parakeet
    SpacingRule.swift         Smart Spacing decision logic: add a leading space whenever
                              resuming a dictation, unless the text before the cursor
                              already ends in whitespace (avoids doubling up). Pure
                              Foundation — unit-tested
    DictationMemory.swift     remembers what Susurro itself last typed and into which
                              app (pid), plus where it ended in a cursorless value;
                              the fallback context when the field can't be read
                              (history/SMART_SPACING_PLAN.md has the v1 rationale)
    TextHandling.swift        pre-insert stage: ContextSource, InsertContext,
                              TextTransform + TextHandlingStage.standard
                              (ContinuationCase → SentenceCase → LeadingSpace);
                              every transform is a pure fn of (text, context)
    ContextProviders.swift    FieldSnapshot (raw AX facts) + ordered pure
                              ContextProviders keyed on the field's *shape*:
                              SelectionRange, EmptyValue, TextMarker, AnchoredValue,
                              AppBridge, Memory; InsertContext.resolve = first answer
                              wins; secure input → nothing read
    EmacsServerProtocol.swift emacsclient line protocol (encode/decode) for the Emacs
                              app bridge
    HandsFreeMachine.swift    hands-free state machine (idle/holding/latchedHeld/
                              latched/…): key events + ticks in, effects out
                              (startRecording, latched, stopAndInsert, cancel,
                              warnAutoStop); idle 60 s / 2 h safety auto-stop;
                              app switch stops. Pure value type, no clock/AppKit
    PauseSegmenter.swift      incremental pause cutter over 16 kHz samples: adaptive
                              noise floor, minPause 1.0 s, minSpeech 0.1 s, 25 s cap
                              (cut at quietest frame); contiguous cuts, no audio lost
    HandsFreeJoin.swift       joins across a pause: holdMark, jointClip (A's last
                              speech + real pause + B's first speech), decide
                              (sentenceBreak / continues / unmatched), joined,
                              shown-mark retraction (canRetract, joinedAfterShown),
                              long-pause lead-in trim; HeldMarkJoiner = per-session
                              held/shown mark state
    ParakeetNumberRules.swift Parakeet-only number formatting fixes
    TranscriptCleaner.swift   optional AI cleanup via FoundationModels (macOS 26 +
                              Apple Intelligence); guided generation (@Generable) so the
                              model can't emit preamble; <6-word skip; sanity-check
                              fallback. TextCleaning protocol = availability-agnostic
                              handle for macOS 15 callers
  Susurro/                  Menu bar app
    main.swift                NSApplication bootstrap, .accessory activation policy
    AppDelegate.swift         CENTRAL COORDINATOR: menu construction, permission flows,
                              model menu (sectioned by engine via
                              ModelManager.menuSections(); size + note in every
                              state), engine load/switch (loadEngine, generation
                              counter discards stale loads), PTT wiring, hands-free
                              wiring (hf* pump/dispatch/end), transcribeAndInsert
                              (the one pipeline both triggers share), notifications,
                              About (incl. Parakeet CC-BY-4.0 attribution)
    HotkeyMonitor.swift       CGEventTap; PTTKey = modifier (flagsChanged) or regular
                              key (keyDown/up, swallowed); latch key + Esc (Esc only
                              swallowed while latched); auto re-enables disabled taps
    TextInjector.swift        CGEvent unicode typing, 18-UTF16-unit chunks, Return for
                              newlines; deleteBackward (guarded shown-mark retraction)
    FocusedFieldReader.swift  Accessibility read of the focused element into a
                              FieldSnapshot, off-main, capped at 250 ms (nil on
                              timeout); secure fields never read; enables AX on
                              Electron apps; consults AppBridges
    AppBridges.swift          per-bundle-ID last-resort bridges; Emacs: one request
                              on the running Emacs server's socket (~2-35 ms), never
                              the minibuffer
    TextHandlingLog.swift     per-app coverage log (source/provider/AX detail —
                              lengths only, never field text), rotated
    OverlayPanel.swift        recording pill: non-activating NSPanel (never steals
                              focus), waveform bars + timer, bottom-right
    ToastPanel.swift          transient acknowledgment toasts, top-right under menu bar
                              (position rationale: same neighborhood as the menu action
                              and later notifications)
    HelpWindow.swift          "Help…" menu item: non-modal window describing the hotkey,
                              every menu item, indicators, and required permissions —
                              keep it in sync when menu items change
  susurro-cli/              transcription harness: susurro-cli <model.bin|parakeet-dir> <wav...>
                              or --engine whisper|parakeet [--model <path>] <wav...>;
                              --post prints raw<TAB>post-processed (fixture corpus
                              regression + engine testing; never downloads)
scripts/ab_engines.py       whisper vs Parakeet WER/latency A/B over
                            Fixtures/ab/references.tsv (raw engine output)
scripts/record_voice_clips.py  records Fixtures/voice/*.wav from references.tsv
                            (the wavs are Matthew's voice and stay untracked)
Tests/SusurroTests/         golden tests (pinned to the Python predecessor's output),
                            filter tests, rules-config tests, ModelManager catalog/
                            download tests, ParakeetEngine + Parakeet post-processing
                            goldens (live download test gated by
                            SUSURRO_LIVE_DOWNLOAD=1), DictationMemory/SpacingRule,
                            TextHandling (providers + transforms),
                            HandsFreeMachine, PauseSegmenter, HandsFreeJoin
Fixtures/                   voice test clips (corpus; add a clip whenever a real-world
                            mishear is worth pinning); Fixtures/ab/ = engine A/B
                            clips + references.tsv (currently `say` stand-ins)
Support/                    Info.plist, entitlements, AppIcon.icns
vendor/whisper.cpp          submodule, pinned v1.9.1
```

## Two triggers, one pipeline

Both triggers end in `AppDelegate.transcribeAndInsert(samples, releasePID:,
releaseBundleID:, expectedPID:, hfChunk:)`. Push-to-talk calls it once per
dictation; hands-free calls it once per pause-cut chunk, chained so chunks are
transcribed and typed strictly in order.

### Push-to-talk

```
key down (CGEventTap callback, main runloop)
  → HandsFreeMachine .startRecording → AppDelegate.pttPressed [MainActor]
      engine not ready → toast says why (loading / downloading / failed)
      AudioRecorder.start()          AVAudioEngine tap begins accumulating samples
      OverlayController.show()       non-activating panel; focus untouched
key up (not latched)
  → .stopAndInsert → pttReleased: samples = recorder.stop(); overlay.hide()
  → transcribeAndInsert(samples, releasePID: frontmost, expectedPID: nil)
```

### Hands-free (latched)

```
hold PTT, tap latch key   → HandsFreeMachine .latched → hfBegin
                            remembers frontmost pid/bundle, fresh PauseSegmenter,
                            HeldMarkJoiner; 100 ms Timer → hfPump; observes app
                            activation (switch → .appSwitched → stop)
hfPump (every 100 ms)       recorder.takeAvailable() → hfFeed → segmenter.append
                            → cuts → hfDispatch; speech → .heardSpeech; .tick drives
                            the idle (60 s) / 2 h auto-stop and its warnings
hfDispatch(cut)             slice the chunk (long lead-in silence trimmed), skip
                            if no speech, append to hfInsertChain:
                            transcribeAndInsert(chunk, expectedPID: hfPID, hfChunk:)
tap PTT / auto-stop         hfEnd(insert: true): flush last segment, then type the
                            final held mark if the same app is still frontmost
Esc                         hfEnd(insert: false): generation bump drops queued
                            chunks and the held mark
```

### transcribeAndInsert

```
[MainActor] if Smart Spacing on and no secure input:
    FocusedFieldReader.read(pid) starts concurrently (Task.detached, ≤250 ms)
Task.detached:
    engine.transcribe()          warm: whisper small.en 0.2–0.7 s (Metal),
                                 Parakeet ~0.07–0.12 s (ANE/Core ML)
    TranscriptFilter             drop [BLANK_AUDIO]-style hallucinations (whisper)
    PostProcessor.process()      rules.json; sentence case deferred to the stage
    [TranscriptCleaner.clean()]  only if AI Cleanup is on
    hands-free chunk only:       HeldMarkJoiner.accept → .fresh (first chunk) or
                                 .needsJoin: transcribe HandsFreeJoin.jointClip of
                                 previous+this chunk, read only the punctuation at
                                 the join → decide → joined text
→ MainActor:
    expectedPID set and another app frontmost → clipboard + toast, never typed
    InsertContext.resolve(snapshot (same app only), DictationMemory, …)
        → first ContextProvider that answers; unknown = empty field
    TextHandlingStage.standard   ContinuationCase, SentenceCase, LeadingSpace
    hands-free joins:            held mode — type the join only if the cursor is
                                 still right after the previous words; shown mode
                                 (readable field) — the previous mark was typed at
                                 the pause, retract it with one guarded Backspace
                                 if the joint transcript says the sentence continues
                                 (canRetract), else leave it; this chunk's own mark
                                 is shown now if the field is readable, else held
    TextHandlingLog.record       source/provider/AX detail, never field text
    TextInjector.type(text)      CGEvent posting into the focused app
    DictationMemory.recordTyped  tail + pid (+ position in a cursorless value);
                                 cleared if nothing was typed
    [clipboard = text]           "Copy Transcript to Clipboard" on (default OFF), or
                                 secure input active (synthetic keys are dropped;
                                 copy + toast keep the words)
```

## Text handling (BEA-648)

- Master toggle: Smart Spacing. Off → no AX read, sentence case only.
- The app target only *collects* facts (`FocusedFieldReader` → `FieldSnapshot`,
  `AppBridges`); all interpretation is pure code in SusurroCore
  (`ContextProviders`, `TextHandling`) and is unit-tested.
- Providers key on the field's shape, not on bundle IDs; adding an app class
  means adding a provider. App bridges are the only per-app code and run
  inside the same 250 ms cap.
- The read runs concurrently with transcription and only counts if the same
  app is still frontmost at insert time.
- Field text is never logged. See `TEXT_HANDLING_FINDINGS.md`.

## Hands-free (BEA-651, BEA-657)

- `HandsFreeMachine` owns the key semantics (latch, stop, Esc, auto-stop, app
  switch); AppDelegate only applies its effects. Pure, unit-tested with
  synthetic timestamps.
- `PauseSegmenter` decides where chunks end; every sample belongs to exactly
  one segment.
- Per-chunk transcription makes every chunk end with a mark. `HandsFreeJoin`
  decides each join's punctuation from a joint clip across the real pause;
  the typed words are always the per-chunk words. Readable fields show the
  mark at the pause and retract it if needed (shown-mark mode); unreadable
  fields hold it until the next join or stop. See `HANDSFREE_JOINS.md`.

## Engines & model catalog

`TranscriptionEngine` (Sendable, warm after init, `transcribe([Float]) → String`
on 16 kHz mono Float32, serialized internally, exposes `kind`) is the only thing
the app and CLI hold. `TranscriptionEngines.load(modelPath:engine:)` calls the
`EngineKind.descriptor.load` closure for the catalog kind (the app passes it) or
infers the kind from the path's shape (directory = first directory engine =
Parakeet, file = whisper; the CLI relies on this).

`Sources/SusurroCore/EngineCatalog.swift` (review R6) is the one place each
engine is described: `EngineKind`, and per kind an `EngineDescriptor` with the
menu section title, `EngineCapabilities` (artifact file/directory, Apple
Silicon only, punctuation, ITN, prompt support, streaming, bracket tokens), the
CLI's default model id and extra lookup paths, and the loader. Callers branch
on capabilities (`TranscriptFilter` on `emitsBracketTokens`, `ModelManager` on
`artifact` and `requiresAppleSilicon`), never on `engine == .x`.

### Adding an engine

1. Write `Sources/SusurroCore/<Name>Engine.swift` conforming to
   `TranscriptionEngine` (warm init from a model path, serialized
   `transcribe`, trimmed plain text, `kind` returns the new case).
2. In `EngineCatalog.swift`, add the `EngineKind` case (declaration order =
   menu order and `kind(ofPath:)` search order) and its `descriptor`:
   capabilities, menu title, default model id, loader. The compiler's
   exhaustive switch points to nothing else.
3. Add the model(s) to `ModelManager.catalog` (`storageName`, `repo`,
   `approxMB`, and `requiredEntries` for directory artifacts). File artifacts
   use the single-file downloader, directories the per-entry one.
4. If the new engine needs behaviour no existing capability covers, add a
   capability flag and branch on it; don't add `kind ==` checks. Two
   directory engines can't be told apart by `kind(ofPath:)`, so CLI users
   pass `--engine` (or `--model` plus the catalog kind) for the second one.
5. Tests: `EngineCatalogTests` checks every descriptor against the catalog
   and runs the filter tests for every `EngineKind.allCases`; add the
   engine's own load/transcribe tests next to `ParakeetEngineTests`.

| Catalog id | Engine | Storage | Approx size | Notes |
|---|---|---|---|---|
| tiny.en, base.en, small.en, medium.en, large-v3-turbo | `.whisper` | single `ggml-*.bin` from `ggerganov/whisper.cpp` | 75 MB – 1.6 GB | `small.en` is the default; large-v3-turbo is multilingual |
| parakeet-tdt-v2 | `.parakeet` | Core ML directory `parakeet-tdt-0.6b-v2-coreml/` from `FluidInference/parakeet-tdt-0.6b-v2-coreml` | 443 MB | English only; Apple Silicon only (`available()` hides it on Intel) |

- Parakeet downloads use Susurro's own `FileDownloader`, not FluidAudio's
  (which has no progress and compiles as part of "download"): list the HF repo
  tree, fetch only the required entries (Preprocessor/Encoder/Decoder/
  JointDecision `.mlmodelc` + `parakeet_vocab.json`) with byte-weighted
  progress into `models/.parakeet-tdt-0.6b-v2-coreml.partial/`, then rename into
  place. The directory name must equal FluidAudio's `folderName` (unit-tested).
  `isDownloaded` requires every required entry.
- Nothing is ever written to `~/Library/Application Support/FluidAudio`.
- Switching models in the menu sets `activeModelID` and reloads the engine
  off-main; a generation counter drops a load that finishes after a newer pick.
- First Parakeet load after download compiles Core ML (~20 s); later loads are
  sub-second.
- Parakeet does its own inverse text normalisation (numbers, currency, times,
  casing, punctuation) but keeps spoken triggers ("comma", "quote") literal, so
  `rules.json` still applies. Custom vocabulary is not supported on Parakeet
  (see `history/VOCABULARY_PROMPT_PLAN.md`, whisper-only).

## Concurrency model

- All UI/menu/AppKit state: `@MainActor` (AppDelegate, panels, HotkeyMonitor).
- Audio tap callbacks arrive on audio threads; `AudioRecorder` is
  `@unchecked Sendable` with an `NSLock`-guarded sample buffer.
- Hands-free state (`HandsFreeMachine`, `PauseSegmenter`, `HeldMarkJoiner`,
  buffers) lives on the main actor; chunk work is serialized through the
  `hfInsertChain` task chain with a generation counter for cancellation.
- `FocusedFieldReader` runs detached and is time-capped; its result is only
  consumed after transcription.
- Transcription runs in `Task.detached` on an `any TranscriptionEngine`; the
  protocol requires `Sendable` and serialized `transcribe`, so each engine
  holds its own lock (`WhisperEngine`: whisper_context is not reentrant;
  `ParakeetEngine`: FluidAudio's `AsrManager` is a non-Sendable class with an
  async API, bridged with a detached task + semaphore under the lock).
- Event-tap C callback runs on the main runloop → `MainActor.assumeIsolated`.
- Strict concurrency is ON (Swift 6). Compile errors around Sendable are the
  norm when touching this code; the patterns above are the house answers.

## Persistence & user data

| What | Where |
|---|---|
| Models | `~/Library/Application Support/Susurro/models/*.bin` (whisper), `.../models/parakeet-tdt-0.6b-v2-coreml/` (Parakeet) |
| Rules | `~/Library/Application Support/Susurro/rules.json` (created from DefaultRules on first run) |
| Active model | UserDefaults `activeModelID` (default "small.en"; unknown/missing ids resolve to the default without rewriting the stored value) |
| PTT key | UserDefaults `pttKeyID` (default rightOption) |
| AI cleanup | UserDefaults `llmCleanupEnabled` (default false) |
| Clipboard copy | UserDefaults `copyToClipboard` (default false; secure-input auto-copy is unconditional) |
| Smart Spacing (text-handling master toggle) | UserDefaults `smartSpacingEnabled` (default false) |
| Latch key | UserDefaults `latchKeyID` (default rightCommand; `LatchKeyResolver` never lets it equal the PTT key) |
| Text-handling coverage log | `TextHandlingLog` file (rotated; no field text) |
| Login item | SMAppService.mainApp |

Note: `activeModelID` has a value even when no model file exists — always pair
with `activeModelPath()` (nil = genuinely no model) when messaging users.

## Constraints & hard-won knowledge (do not relearn these)

- **No App Sandbox, ever**: sandboxed apps cannot create active CGEventTaps.
  This also rules out the Mac App Store permanently.
- **SPM resources (`Bundle.module`) are forbidden** in this repo: the generated
  accessor only resolves at the dev build path or `.app/`-root, not
  `Contents/Resources/` of a hand-assembled bundle. Embed data in Swift instead
  (see DefaultRules.swift; this crashed 0.1.0 on every non-dev machine).
- **TCC (mic/Accessibility) is keyed to the code signature.** The self-signed
  "Susurro Dev" identity exists so rebuilds keep their grants (ad-hoc signatures
  change every build → permissions reset). Moving the .app path re-prompts
  Accessibility.
- **The menu-bar mic pill cannot be avoided** by a legitimate mic-recording app:
  signature, API (AVAudioEngine vs raw HAL), launch context, activation policy,
  and entitlements were all tested — only the capture *route* matters, and the
  ScreenCaptureKit route trades it for a worse indicator + Screen Recording
  permission + start latency. Full experiment log in history/PLAN.md.
- **whisper small.en beat Apple's SpeechTranscriber** on technical vocabulary
  and verbal-punctuation handling in the original spike (see ptt repo
  spike/ and history/PLAN.md). Engines now sit behind `TranscriptionEngine`; Parakeet
  TDT v2 was added as an option (2.4% vs 11.4% WER on the A/B corpus, ~3.5×
  faster), but `small.en` stays the default. See history/PARAKEET_PLAN.md.
- **FluidAudio's `AsrModels.load(from:)` silently re-downloads ~450 MB** into the
  directory's parent if files are missing. `ParakeetEngine` checks
  `modelsExist(at:version:)` first and throws `modelFilesMissing` instead.
- **FluidAudio ASR is Apple Silicon only** (throws `unsupportedPlatform` on
  Intel); the catalog hides Parakeet there. Core ML prints a harmless one-off
  `E5RT ... zero shape error` line on first inference.
- **FluidAudio ships no SPM resources** (checked at 0.9.1), so it doesn't hit
  the `Bundle.module` ban above. Re-check on every version bump.
- **whisper.cpp is linked statically** (`make whisper` → `build-whisper/`,
  flags in Package.swift `whisperLinkerSettings`), Metal embedded
  (`GGML_METAL_EMBED_LIBRARY=ON`), OpenMP disabled (Homebrew libomp leak).
- **Whisper hallucinates on silence** ("[BLANK_AUDIO]") — TranscriptFilter
  strips square-bracket tokens; parentheses are preserved deliberately.
- **Reading a focused field's content via Accessibility does not generalize
  across apps with one attribute.** (0.2.0 answers this with shape-keyed
  providers + app bridges + self-tracking fallback, above.) `kAXSelectedTextRangeAttribute` (cursor position) is only
  reliably implemented by native Cocoa text views. Electron apps and
  Chromium/WebKit web content expose cursor position via a different,
  non-standard mechanism (`AXTextMarkerRange`); Terminal's custom-drawn text
  view doesn't expose per-character selection via AX at all. An
  AX-read-based Smart Spacing design was built, tested, and abandoned for
  this reason (empirically: it worked in TextEdit, silently did nothing in
  Claude desktop/Terminal/browser fields) in favor of `DictationMemory`
  self-tracking what Susurro itself typed. See history/SMART_SPACING_PLAN.md
  and TEXT_HANDLING_FINDINGS.md for the 0.2.0 redesign.
- ~600 MB resident with small.en warm; scales with model choice. Parakeet's
  in-process RSS reads far lower (~93 MB in the BEA-632 spike) because Core ML/ANE
  weights live outside resident pages; its real in-app footprint has not been
  measured yet.

## Debug affordances

- Run `./build/Susurro.app/Contents/MacOS/Susurro` directly from a terminal to
  see stderr logs (via `open`/LaunchServices, NSLog content is TCC-redacted in
  `log show`).
- `susurro-cli <model.bin> Fixtures/*.wav` (or `--engine parakeet`) — corpus
  regression in seconds; `--post` shows raw vs post-processed text.
- `scripts/ab_engines.py` — whisper vs Parakeet WER/latency A/B over
  `Fixtures/ab/references.tsv`.
