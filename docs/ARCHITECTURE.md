# Susurro — Architecture (as built)

This file describes what actually exists on `main` after the 2026-11
architecture review's refactors R0–R8 (R0–R6 checked against 9d0398b, after
0.2.0-beta.3; R7 logging added by BEA-683; R8 model-swap policy by BEA-684): push-to-talk, hands-free latching with pause-cut chunks and
joins, cross-dictation joins, the pre-insert text-handling stage, and the
whisper.cpp + Parakeet engines. The review and its per-finding status are in
`history/ARCHITECTURE_REVIEW_2026-11.md`; its open items are listed under
"Known open items" at the end of this file.

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
                            exact 0.9.1. Targets: CWhisper, SusurroCore, Susurro,
                            susurro-cli, SusurroTests
.github/workflows/ci.yml    CI (review R5): macOS runner, cached whisper.cpp build,
                            swift build + swift test on PRs and main; no signing,
                            releases stay local (docs/releasing.md)
Sources/
  CWhisper/                 C shim exposing vendor whisper.h to Swift (empty .c + header)
  SusurroCore/              Library shared by app, CLI, tests (no AppKit UI)
    -- engines & models --
    TranscriptionEngine.swift Engine protocol (warm load, 16 kHz in, serialized
                              transcribe → trimmed text, `kind`) +
                              TranscriptionEngines.load / kind(ofPath:); app and
                              CLI depend on these only
    EngineSlot.swift          (R8) model-swap memory policy: current engine +
                              per-dictation EngineLease; old engine freed when
                              in-flight work drains, swaps logged
    EngineCatalog.swift       (R6) EngineKind + per-kind EngineDescriptor: menu
                              title, EngineCapabilities (artifact file/directory,
                              Apple Silicon only, punctuation, ITN, prompt,
                              streaming, bracket tokens), CLI default model +
                              lookup paths, loader closure. The only place that
                              switches on the engine kind
    WhisperEngine.swift       whisper.cpp C API wrapper (TranscriptionEngine); model
                              loaded once, stays warm; transcribe() internally
                              serialized (ctx not reentrant)
    ParakeetEngine.swift      Parakeet TDT v2 via FluidAudio (TranscriptionEngine):
                              AsrModels.load(from: Susurro models dir) — never
                              downloads (checks modelsExist first); AsrManager is
                              non-Sendable, so NSLock + detached task/semaphore bridge
                              async → sync; pads <1 s buffers to 16,000 samples
    ModelManager.swift        model catalog (CatalogModel entries carry an EngineKind:
                              5 whisper ggml files + Parakeet TDT v2 Core ML
                              directory); HuggingFace download with progress
                              (FileDownloader; file vs per-entry directory download
                              chosen by the kind's `artifact` capability),
                              available() (hides requiresAppleSilicon kinds on
                              Intel), active-model selection, legacy-path seed
    -- audio --
    AudioRecorder.swift       PRODUCTION capture: AVAudioEngine input tap → 16kHz mono
                              Float32 in RAM; peak-level callback; config-change
                              (mic unplugged) interruption callback;
                              takeAvailable() drains new samples while recording
                              (hands-free pump). Conforms to AudioSource
    AudioFileLoader.swift     any audio file → 16kHz mono Float32 (used by CLI/tests)
    AudioResampler.swift      shared mono resample helper
    -- transcript side of a dictation --
    DictationPipeline.swift   (R2) transcribe → TranscriptFilter → PostProcessor →
                              optional LLM cleaner (clean / cleanDictation /
                              postProcessed), plus the joint-clip re-transcriptions
                              that decide joins: handsFreeStep (hands-free) and
                              crossDecision (cross-dictation); replayHandsFree
                              for the CLI. App and CLI both run it; no AX,
                              pasteboard or main actor
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
    TranscriptFilter.swift    strips whisper hallucination tokens ([BLANK_AUDIO] etc.)
                              when the kind's `emitsBracketTokens` capability is set,
                              so dictated brackets survive on Parakeet
    ParakeetNumberRules.swift Parakeet-only number formatting fixes
    TranscriptCleaner.swift   optional AI cleanup via FoundationModels (macOS 26 +
                              Apple Intelligence); guided generation (@Generable) so the
                              model can't emit preamble; <6-word skip; sanity-check
                              fallback. TextCleaning protocol = availability-agnostic
                              handle for macOS 15 callers
    -- insert side of a dictation --
    InsertPlan.swift          (R2) pure insert decision for one dictation:
                              InsertPlan.make(processed, join, context, stage, …) →
                              .insert(text, deleteBackward) or skip, markShown,
                              cross-join log fields, notes; appSwitchClipboardText
    InsertionQueue.swift      (R3) InsertionQueue: @MainActor serial FIFO of jobs,
                              each with an isCurrent gate (skipped when stale);
                              InsertExecutor: keystrokes, clipboard / secure-input /
                              app-switch policy, owns DictationMemory; seams
                              Inserter, FrontmostAppProvider, Clipboard; HeldMarkTail
    DictationTiming.swift     (R1) SessionGate (hands-free cancel token), GatedChunk
                              (the chunk step, testable with a slow fake engine),
                              CappedRead (real time cap on blocking work),
                              StageTimings (ms_ax / ms_transcribe / ms_join /
                              ms_insert log fields)
    Logging.swift             (R7) Log: os.Logger per category (dictation, engine,
                              handsfree, textHandling) under subsystem = bundle id
                              (com.mtwomey.susurro); Logger.event/failure (public,
                              text-free lines); Log.transcript (debug + private
                              only). DictationRecord: the one structured record per
                              dictation (trigger, engine, outcome, source/provider,
                              app, AX detail, cross-join fields, StageTimings) —
                              no text-carrying fields
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
    CrossDictationJoin.swift  (BEA-677) eligibility guard for joining a dictation to
                              Susurro's previous one (Previous, Current, check,
                              worthDeciding, decide, edit, speechBounds, logLine):
                              removes the previous "." only when every check proves
                              it is still the last thing before the cursor
    -- hands-free --
    HandsFreeMachine.swift    hands-free state machine (idle/holding/latchedHeld/
                              latched/…): key events + ticks in, effects out
                              (startRecording, latched, stopAndInsert, cancel,
                              warnAutoStop); idle 60 s / 2 h safety auto-stop;
                              app switch stops. Pure value type, no clock/AppKit
    HandsFreeSession.swift    (R4) hands-free audio plumbing: AudioSource protocol;
                              pump (drain + segment → speech chunks, heardSpeech),
                              finish (flush the last segment), discard. Pure;
                              tested with fixture audio
    PauseSegmenter.swift      incremental pause cutter over 16 kHz samples: adaptive
                              noise floor, minPause 1.0 s, minSpeech 0.1 s, 25 s cap
                              (cut at quietest frame); contiguous cuts, no audio lost
    HandsFreeJoin.swift       joins across a pause: holdMark, jointClip (A's last
                              speech + real pause + B's first speech), decide
                              (sentenceBreak / continues / unmatched), joined,
                              shown-mark retraction (canRetract, joinedAfterShown),
                              long-pause lead-in trim; HeldMarkJoiner = per-session
                              held/shown mark state
    -- settings --
    Settings.swift            (R4) Settings: one typed façade over the UserDefaults
                              keys (key strings unchanged, migration-free);
                              Tuning: the code-default constants (segmenter config,
                              hands-free limits, AX cap + messaging timeout,
                              slow-load threshold) and their factories
  Susurro/                  Menu bar app
    main.swift                NSApplication bootstrap, .accessory activation policy
    AppDelegate.swift         WIRING ONLY (~320 lines after R4): owns the services
                              (Settings/Tuning, InsertionQueue, InsertExecutor,
                              EngineController, DictationController,
                              StatusMenuController, DevHooks, HotkeyMonitor),
                              permission flows, PTT press/release, hands-free
                              wiring (hfEvent/hfApply/hfBegin/hfPump/hfDispatch/
                              hfEnd: timer, app-switch observer, queueing);
                              logging via SusurroCore Log (os.Logger, R7)
    DictationController.swift (R4) transcribeAndInsert — one dictation (PTT release,
                              hands-free chunk, dev feed), run inside an
                              InsertionQueue job: DictationPipeline off-main, then on
                              the main actor InsertContext.resolve → InsertPlan.make
                              → InsertExecutor.insert. Owns SessionGate,
                              HeldMarkJoiner, previous chunk and cross-dictation
                              state
    EngineController.swift    (R4) model lifecycle: loaded engine (EngineSlot, R8), load generation
                              (a load that finishes after a newer pick is dropped),
                              State (loading/downloading/failed/ready), download-
                              and-switch, first-run auto-download, toasts and
                              notifications
    StatusMenuController.swift (R4) status item + menu: construction, status line
                              (model load/download, sticky mic-denied), model menu
                              (sectioned by engine; size + note in every state),
                              key / latch / toggle actions
    Alerts.swift              (R4) About (incl. Parakeet CC-BY-4.0 attribution) and
                              Apple Intelligence instructions alerts
    DevHooks.swift            (R4) developer-only feed-a-WAV and context-probe hooks
                              (BEA-677); off unless DevFeedHook is set
    SystemSeams.swift         (R3) real seams: KeystrokeInserter (TextInjector),
                              GeneralPasteboard, SystemFrontmostApp (NSWorkspace +
                              secure-input state)
    HotkeyMonitor.swift       CGEventTap; PTTKey = modifier (flagsChanged) or regular
                              key (keyDown/up, swallowed); latch key + Esc (Esc only
                              swallowed while latched); auto re-enables disabled taps
    TextInjector.swift        CGEvent unicode typing, 18-UTF16-unit chunks, Return for
                              newlines; deleteBackward (guarded shown-mark retraction)
    FocusedFieldReader.swift  Accessibility read of the focused element into a
                              FieldSnapshot, off-main, capped via CappedRead at
                              Tuning.axReadCap (250 ms; nil on timeout); secure
                              fields never read; enables AX on Electron apps;
                              consults AppBridges
    AppBridges.swift          per-bundle-ID last-resort bridges; Emacs: one request
                              on the running Emacs server's socket (~2-35 ms), never
                              the minibuffer
    TextHandlingLog.swift     per-app coverage file: DictationRecord.line for each
                              dictation that reached the insert step (lengths and
                              numbers only, never field text), rotated at 1 MB
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
                              --post prints raw<TAB>post-processed; hands-free join
                              replay. Runs the app's DictationPipeline (R2), so eval
                              output is the app's behaviour by construction; never
                              downloads
scripts/ab_engines.py       whisper vs Parakeet WER/latency A/B over
                            Fixtures/ab/references.tsv (raw engine output)
scripts/handsfree_join_eval.py, xjoin_eval.py (+ xjoin_pairs.tsv)
                            hands-free / cross-dictation join evaluations via the CLI
scripts/feed_wav.sh, context_probe.py
                            drive the DevHooks feed / context probe in a running app
scripts/record_voice_clips.py  records Fixtures/voice/*.wav from references.tsv
                            (the wavs are Matthew's voice and stay untracked)
scripts/pad_eval.py, pad_sweep.py, mel_norm_probe.py
                            one-off engine experiments
Tests/SusurroTests/         SusurroCore only (no app target): golden tests (pinned to
                            the Python predecessor's output), filter + EngineCatalog
                            (filter tests run for every EngineKind), rules/Settings,
                            ModelManager catalog/download, ParakeetEngine + Parakeet
                            post-processing goldens (live download test gated by
                            SUSURRO_LIVE_DOWNLOAD=1), DictationMemory/SpacingRule/
                            StaleMemory/EmptyFieldEcho, TextHandling, DictationPipeline,
                            InsertPlan, InsertionQueue (fake Inserter/Frontmost/
                            Clipboard), DictationTiming (SessionGate, CappedRead),
                            HandsFreeMachine, HandsFreeSession (fixture audio),
                            PauseSegmenter, HandsFreeJoin, CrossDictationJoin
Fixtures/                   voice test clips (corpus; add a clip whenever a real-world
                            mishear is worth pinning); Fixtures/ab/ = engine A/B
                            clips + references.tsv (currently `say` stand-ins)
Support/                    Info.plist, entitlements, AppIcon.icns
vendor/whisper.cpp          submodule, pinned v1.9.1
```

## One dictation, end to end

Both triggers enqueue a job on the one `InsertionQueue` (AppDelegate owns it).
Each job calls `DictationController.transcribeAndInsert(samples, releasePID:,
releaseBundleID:, expectedPID:, hfChunk:, hfToken:)`, which runs the
`DictationPipeline` off-main and then plans (`InsertPlan`) and carries out
(`InsertExecutor`) the insert on the main actor. Push-to-talk enqueues one job
per dictation; hands-free one per pause-cut chunk plus a final held-mark job.
A job starts only after the previous one has finished, so dictations from both
triggers type strictly in order and never interleave their DictationMemory
updates (review F3, R3).

```
trigger ──► InsertionQueue.enqueue(isCurrent:) ──► DictationController.transcribeAndInsert
                                                     ├─ DictationPipeline (detached)
                                                     └─ [MainActor] InsertContext.resolve
                                                        → InsertPlan.make → InsertExecutor.insert
```

### Push-to-talk

```
key down (CGEventTap callback, main runloop)
  → HandsFreeMachine .startRecording → AppDelegate.pttPressed [MainActor]
      engine not ready → toast with EngineController.unavailableMessage
      AudioRecorder.start()          AVAudioEngine tap begins accumulating samples
      OverlayController.show()       non-activating panel; focus untouched
key up (not latched)
  → .stopAndInsert → pttReleased: samples = recorder.stop(); overlay.hide()
  → insertionQueue.enqueue { dictation.transcribeAndInsert(samples,
        releasePID: frontmost, expectedPID: nil) }
```

The dev feed hook (`DevHooks`) enqueues a WAV the same way.

### Hands-free (latched)

```
hold PTT, tap latch key   → HandsFreeMachine .latched → hfBegin
                            remembers frontmost pid/bundle, fresh HandsFreeSession,
                            fresh HeldMarkJoiner on DictationController; 100 ms
                            Timer → hfPump; observes app activation
                            (switch → .appSwitched → stop)
hfPump (every 100 ms)       hfSession.pump(recorder): takeAvailable → PauseSegmenter
                            → speech chunks (long lead-in silence trimmed, no-speech
                            cuts dropped) → hfDispatch; heardSpeech → .heardSpeech;
                            .tick drives the idle (60 s) / 2 h auto-stop + warnings
hfDispatch(chunk)           token = dictation.gate.token;
                            insertionQueue.enqueue(isCurrent: gate.isCurrent(token))
                            { transcribeAndInsert(chunk, expectedPID: hfPID,
                              hfChunk:, hfToken: token) }
tap PTT / auto-stop         hfEnd(insert: true): hfSession.finish flushes the last
                            segment → hfDispatch; then one more gated job types the
                            final held mark (InsertExecutor.typeHeldMark /
                            HeldMarkTail: same app still frontmost, no secure input)
Esc                         hfEnd(insert: false): hfSession.discard; gate.cancel()
                            makes every queued job skip and a chunk that is
                            mid-transcription drop at insert; joiner.discard()
```

### DictationController.transcribeAndInsert

```
[MainActor] if Smart Spacing on, no secure input:
    FocusedFieldReader.read(pid) starts concurrently (Task.detached; CappedRead,
    ≤ Tuning.axReadCap = 250 ms, nil on timeout)
Task.detached — DictationPipeline:
    engine.transcribe()           warm: whisper small.en 0.2–0.7 s (Metal),
                                  Parakeet ~0.07–0.12 s (ANE/Core ML)
    cleanDictation()              TranscriptFilter (bracket tokens if the engine's
                                  capability says so) → PostProcessor (rules.json;
                                  sentence case deferred to the stage) →
                                  [TranscriptCleaner] if AI Cleanup is on
    hands-free chunk only:        [MainActor, gate re-checked] HeldMarkJoiner.accept
                                  → handsFreeStep: .fresh, or transcribe
                                  HandsFreeJoin.jointClip of previous+this chunk,
                                  read only the punctuation at the join → decide
    push-to-talk only:            crossDecision: if CrossDictationJoin.worthDeciding
                                  (same app, short gap, previous ended in "."),
                                  transcribe a joint clip with the previous
                                  dictation and decide its full stop
    StageTimings                  ms_ax / ms_transcribe / ms_join
→ MainActor:
    gate.isCurrent(hfToken) false → dropped (session cancelled mid-transcription)
    expectedPID set and another app frontmost → InsertExecutor.copyAfterAppSwitch
                                  (clipboard + toast, held mark travels along),
                                  joiner discarded, never typed
    InsertContext.resolve(snapshot (same app only), DictationMemory, …)
        → first ContextProvider that answers; unknown = empty field
    InsertPlan.make               pure: TextHandlingStage.standard (ContinuationCase,
                                  SentenceCase, LeadingSpace); hands-free joins —
                                  held mode types the join only if the cursor is
                                  still right after the previous words; shown mode
                                  (readable field) retracts the previous shown mark
                                  with one guarded Backspace if the joint transcript
                                  says the sentence continues (canRetract); this
                                  chunk's own mark is shown now if the field is
                                  readable, else held; cross-dictation —
                                  CrossDictationJoin.check field guards, then
                                  edit (one Backspace + lower-cased continuation)
                                  → .insert(text, deleteBackward) or nothing
    InsertExecutor.insert         Backspaces + TextInjector.type via the Inserter
                                  seam; DictationMemory.recordTyped (tail + pid,
                                  + position in a cursorless value) or clear on
                                  secure input / failed keystroke / unknown app;
                                  clipboard if "Copy Transcript to Clipboard" (default
                                  OFF) or secure input blocked typing (+ toast)
    TextHandlingLog.record        source/provider/AX detail + StageTimings incl.
                                  ms_insert, never field text
    joiner.markShown / xPrev      shown mark confirmed; PTT keeps the record + audio
                                  for the next cross-dictation decision
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
  switch); AppDelegate only applies its effects (timer, app-switch observer,
  queueing). `HandsFreeSession` owns the audio plumbing (drain, segment,
  flush) and is tested with fixture audio. Pure, unit-tested with
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
- Switching models in the menu sets `activeModelID` and `EngineController`
  reloads the engine off-main; its generation counter drops a load that
  finishes after a newer pick.
- **Model-swap memory policy (R8, F7; `SusurroCore/EngineSlot.swift`).**
  `EngineController` keeps the engine in an `EngineSlot`. Each dictation takes
  an `EngineLease` at key release (`DictationController`) and holds it until
  its job ends, so a dictation started before a switch finishes on the engine
  it started with — never dropped, never re-routed to the new model. When a
  load starts, the slot drops its own reference to the old engine
  (`retire()`); the old engine then lives only as long as in-flight leases
  and is freed when the last one finishes. With nothing in flight it is freed
  at once, so old + new (~600 MB for small.en plus Parakeet Core ML) are only
  both resident while a dictation still needs the old one. Push-to-talk is
  ignored while no engine is installed (unchanged). Each step is logged on
  `Log.engine`: `model swap: old <kind> engine released (nothing in flight)`,
  `… kept for N in-flight dictation(s)`, `… released after in-flight work
  drained`, `model swap: <kind> engine installed`. Tested with a
  deinit-tracking fake engine (`EngineSlotTests`).
- First Parakeet load after download compiles Core ML (~20 s); later loads are
  sub-second.
- Parakeet does its own inverse text normalisation (numbers, currency, times,
  casing, punctuation) but keeps spoken triggers ("comma", "quote") literal, so
  `rules.json` still applies. Custom vocabulary is not supported on Parakeet
  (see `history/VOCABULARY_PROMPT_PLAN.md`, whisper-only).

## Concurrency model

- All UI/menu/AppKit state: `@MainActor` (AppDelegate, StatusMenuController,
  EngineController, DictationController, DevHooks, panels, HotkeyMonitor).
- Audio tap callbacks arrive on audio threads; `AudioRecorder` is
  `@unchecked Sendable` with an `NSLock`-guarded sample buffer.
- Insertion order: every dictation (push-to-talk, hands-free chunk, held-mark
  tail, dev feed) is a job on the one `@MainActor InsertionQueue`. A job awaits
  the previous job's task before it runs, so jobs never overlap, across
  triggers too. Only `InsertExecutor` (called from those jobs) writes
  `DictationMemory`.
- Cancellation: `SessionGate` is a generation token on DictationController.
  Esc calls `gate.cancel()`; a hands-free job carries the token it was queued
  with and is checked three times — by the queue when its turn comes
  (`isCurrent`), before `HeldMarkJoiner.accept`, and again just before
  insert, because a chunk can be mid-transcription when the user cancels
  (F2, R1). Push-to-talk passes `nil` = always current. `GatedChunk` mirrors
  this for tests.
- Hands-free state (`HandsFreeMachine`, `HandsFreeSession`, `HeldMarkJoiner`,
  previous chunk) lives on the main actor.
- `FocusedFieldReader` runs detached under `CappedRead`: the blocking AX read
  goes to a dispatch queue and a continuation is resumed once by whichever
  finishes first (result or cap), so the read really returns nil at 250 ms; a
  late result is dropped (F5, R1). A task group would have waited for the
  non-cancellable AX call. The result is only consumed after transcription.
- Transcription (and the joint-clip re-transcriptions) runs in `Task.detached`
  through `DictationPipeline` on an `any TranscriptionEngine`; the protocol
  requires `Sendable` and serialized `transcribe`, so each engine holds its own
  lock (`WhisperEngine`: whisper_context is not reentrant; `ParakeetEngine`:
  FluidAudio's `AsrManager` is a non-Sendable class with an async API, bridged
  with a detached task + semaphore under the lock).
- Engine loads: `EngineController` loads off-main and discards stale results by
  generation.
- Event-tap C callback runs on the main runloop → `MainActor.assumeIsolated`.
- Strict concurrency is ON (Swift 6). Compile errors around Sendable are the
  norm when touching this code; the patterns above are the house answers.

## Persistence & user data

All UserDefaults keys are declared in `Settings.Key` (SusurroCore/Settings.swift);
the key strings are the persisted names and never change.

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
| Dev hooks | UserDefaults `DevFeedHook` (default false; no UI) |
| Tuning constants | code defaults in `Tuning` (not read from defaults) |
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

- Logs are `os.Logger` (R7): `log stream --level info --predicate
  'subsystem == "com.mtwomey.susurro"'` (categories dictation, engine,
  handsfree, textHandling). Diagnostic lines are public and carry no user
  text. Every dictation emits one `record trigger=… engine=… outcome=…
  source=… provider=… app=… ax=… sameApp=… [xjoin…] ms_ax ms_transcribe
  ms_join ms_insert` line in category dictation, whatever its outcome
  (inserted, empty, nothingToType, notInserted, clipboardAppSwitch, dropped).
  The transcript is logged only at debug level with `privacy: .private`
  (redacted unless private logging is enabled); field text is never logged.
- `susurro-cli <model.bin> Fixtures/*.wav` (or `--engine parakeet`) — corpus
  regression in seconds; `--post` shows raw vs post-processed text.
- `scripts/ab_engines.py` — whisper vs Parakeet WER/latency A/B over
  `Fixtures/ab/references.tsv`.
- `~/Library/Logs/Susurro/text-handling.log` (TextHandlingLog) is kept
  (R7 decision): TEXT_HANDLING_FINDINGS.md and HANDSFREE_JOINS.md read
  per-app coverage from it and it outlives unified-log retention. It holds
  the same `DictationRecord` line (timestamped) for each dictation that
  reached the insert step; the unified log has every dictation.
- Dev hooks (`defaults write <bundle id> DevFeedHook -bool YES`):
  `scripts/feed_wav.sh clip.wav` dictates a WAV into the frontmost app;
  `scripts/context_probe.py` runs the pre-insert pipeline without typing.

## Known open items (after R0–R8)

- **F13 — PostProcessor re-reads rules.json on every call.** By design (live
  reload); fine as is. Add an mtime check only if it ever shows in a profile.
- **Flake to watch: the wall-clock `CappedRead` test**
  (DictationTimingTests). It failed once on CI at the R4 merge (f7c370c, CI
  run 42176342630) when the CPU-bound HandsFreeSessionTests starved it on the
  3-core runner; b1f215b mitigated it (fixture loaded once, those tests
  serialized). If it fails again, widen its margins or make it clock-free
  rather than re-running.
