# Parakeet TDT v2 engine — plan and feasibility spike

Parent: BEA-631. Board decisions: BEA-630. This document starts with the BEA-632
feasibility spike; later tickets (633–640) extend it.

## Goal

Add NVIDIA Parakeet TDT 0.6B v2 (English, CC-BY-4.0, Core ML) as an
**additional** engine option via FluidAudio. `small.en` stays the default;
existing users' `activeModelID` is untouched. Custom vocabulary is out of scope.

## Spike (BEA-632) — verdict: GO

Run on 2026-11-04, Apple Silicon, macOS 26.6.2, Xcode SDK 27.2, deployment
target macOS 15.0, branch `feature/parakeet-v2`.

### What was built

- `Package.swift`: `FluidAudio` pinned `exact: "0.9.1"`, product linked into
  `SusurroCore`.
- `Sources/SusurroCore/ParakeetEngine.swift`: minimal wrapper —
  `AsrModels.downloadAndLoad(version: .v2)` → `AsrManager.initialize(models:)` →
  `transcribe(samples:)` (16 kHz mono Float32, same contract as `WhisperEngine`).
- `Sources/parakeet-spike/main.swift`: harness that loads the model and
  transcribes each file twice (first inference, then warm).
- Not wired into `AppDelegate` / `ModelManager` yet (BEA-633+).

### Blocker checks

| Risk | Result |
|---|---|
| NemoTextProcessing dependency | **None.** FluidAudio 0.9.1 `Package.swift` has `dependencies: []`. |
| Minimum OS mismatch | **None.** FluidAudio requires macOS 14; Susurro targets 15. |
| Bundle/resources (`Bundle.module` crash, cf. 0.1.0) | **None.** The `FluidAudio` library target declares no resources (only the CLI target does); no `.bundle` is produced, `make app` needs no change. Models live outside the app. |
| Coexistence with whisper `unsafeFlags` | **Works after a manifest fix** (below). |
| Intel Macs | FluidAudio ASR throws `unsupportedPlatform` off Apple Silicon. The engine option must be hidden/disabled on Intel. |

### Required build fix (keep it in BEA-633)

With the FluidAudio package dependency present, `swift build` failed:
`'whisper.h' file not found` while scanning module `CWhisper`. Two causes seen
in the compiler command line:

1. The build ran with `-working-directory` set to the **parent** of the package
   (`~/Git_Repos`), so the relative `-Ivendor/...` / `-Lbuild-whisper/...` flags
   resolved to the wrong place.
2. `cSettings` include paths are not passed to `swiftc`'s clang dependency
   scanner for Swift targets that import `CWhisper` (directly or transitively).

Fix applied in `Package.swift`:

- `let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path`
  and all whisper `-I`/`-L` flags made absolute (`\(root)/...`).
- New `whisperSwiftSettings` (`-Xcc -I\(root)/vendor/whisper.cpp/include`, and
  the `ggml/include` path) applied to `SusurroCore`, `Susurro`, `susurro-cli`,
  `parakeet-spike` and `SusurroTests`.

After this, `make app` (builds and signs `build/Susurro.app`) and `make test`
(29 tests in 4 suites) both pass.

### Measurements (Fixtures/*.wav, 3 × 15.00 s + 9.79 s)

| Metric | whisper small.en (`susurro-cli`) | Parakeet v2 (`parakeet-spike`) |
|---|---|---|
| Model on disk | 488 MB (`ggml-small.en.bin`) | 452 MB (`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2-coreml`) |
| First-ever load | 11.32 s (cold file cache) | 157.3 s, which includes the ~452 MB HF download and the first Core ML compile |
| Load, models cached | 0.53 s | 0.38 s |
| Per-clip latency, 15 s clip | 0.26–0.42 s (warm), 0.23–0.79 s (cold) | 0.071–0.083 s warm, 0.078–0.117 s first pass |
| Per-clip latency, 9.79 s clip | 0.29–0.30 s | 0.072–0.074 s |
| Realtime factor | 33–66× | 133–211× |
| Peak RSS (whole process) | 713–719 MB | 93 MB cached run; 508 MB on the first run (download + compile) |
| App binary | 2.73 MB (main `build/Susurro.app`) | 4.80 MB with FluidAudio linked: **+2.07 MB** |
| App bundle (`du`) | 2.9 MB | 4.8 MB: **+1.9 MB** (no added resources) |

Caveats:
- The Parakeet RSS figure is `/usr/bin/time -l` max RSS. Core ML/ANE weights are
  mapped and largely held outside the process's resident pages, so 93 MB
  understates the system-wide cost. BEA-633+ should recheck it in-app with
  Activity Monitor or footprint.
- The binary delta compares against the existing main-checkout bundle. The app
  doesn't call `ParakeetEngine` yet, so the dead-strip result may change once it
  is wired in. Expect a few MB at most; the model is never bundled.
- Each run logs a Core ML warning, `E5RT ... slice_by_index: zero shape error`,
  twice during load. It isn't fatal, and every transcription succeeded.

### Transcripts (Parakeet v2, first pass)

- clip1: "The invoice for $479.50 is due March 3rd. Call me at 555-212-3456 around 9:45 a.m."
- clip2: "Refactor the Python daemon to use a Unix socket instead of a named pipe, then update the Launch DD list and rebuild whisper CPP with Metal Acceleration."
- clip3: "Add a comment that says quote this is a temporary workaround end quote, comma, then file a ticket, period."
- smoke: "The meeting is at 3:30 p.m. on January 22nd. The budget is $245,000, which is about 12% higher than last year"

Parakeet applies its own inverse text normalisation: numbers, currency, times
and punctuation come out formatted. Spoken punctuation such as "comma",
"period" and "quote" stays literal, as with Whisper, so `PostProcessor` still
applies. Jargon errors like "Launch DD" (launchd) and "whisper CPP" are where
the deferred vocabulary feature would help.

### Implications for the following tickets

- Models download through FluidAudio into its own Application Support folder.
  `ModelManager` should either pass `downloadAndLoad(to:)` a Susurro-owned
  directory or track FluidAudio's default one. The first load includes a slow
  one-time download and compile (minutes), so it needs progress UI.
- `AsrManager` is a non-`Sendable` class with an async API. The engine wrapper
  needs an actor or isolated owner under Swift 6 strict concurrency.
- Gate the option to Apple Silicon.
- Remove the `parakeet-spike` target, or keep it as a dev harness, before BEA-639.

## Model catalog and download manager (BEA-634)

- `CatalogModel` (alias `WhisperModel` for source compatibility) carries an
  `EngineKind`: `.whisper` (single ggml file) or `.parakeet` (Core ML model
  directory). New entry `parakeet-tdt-v2`, ~443 MB, repo
  `FluidInference/parakeet-tdt-0.6b-v2-coreml`. `ModelManager.available()`
  hides it off Apple Silicon.
- **Downloader decision: Susurro's `FileDownloader`, not FluidAudio's.**
  FluidAudio's `AsrModels.download(to:)` has no progress callback (its
  `ProgressHandler` is documented as unused), and it compiles/loads every model
  as part of "download", so the menu could only show an indeterminate wait of
  minutes. Susurro lists the HF repo tree
  (`/api/models/<repo>/tree/main?recursive=true`), fetches only the files under
  the five required entries (`Preprocessor`, `Encoder`, `Decoder`,
  `JointDecision` `.mlmodelc`, `parakeet_vocab.json`; 21 files, 464,413,247
  bytes on 2026-11-04) with byte-weighted progress into
  `models/.parakeet-tdt-0.6b-v2-coreml.partial/`, then renames it to
  `~/Library/Application Support/Susurro/models/parakeet-tdt-0.6b-v2-coreml/`.
  A partial download never counts as `isDownloaded`. The directory name equals
  FluidAudio's `folderName` (unit-tested) because `AsrModels.load(from:version:)`
  resolves files relative to it; BEA-635 loads with
  `AsrModels.load(from: path, version: .v2)`, never `downloadAndLoad`, so
  nothing is written to `~/Library/Application Support/FluidAudio`.
- `delete` removes the directory (and any staging leftovers); `isDownloaded`
  requires every required entry.
- **activeModelID migration:** the key and stored values are unchanged. Every
  value a released build wrote is a whisper catalog id and resolves to itself;
  nil or unknown values resolve to `small.en` without rewriting the default.
  Existing whisper users see no change.
- (Superseded by BEA-635: the menu now lists Parakeet too.)
- Tests: `Tests/SusurroTests/ModelManagerTests.swift` (12 unit tests: catalog,
  engine kinds, Intel gating, migration, file/directory storage, HF listing
  filter). One env-gated live test
  (`SUSURRO_LIVE_DOWNLOAD=1 swift test --filter liveParakeet`) passed on
  2026-11-04: real download to a scratch directory, 1,464 progress callbacks up
  to 1.0, FluidAudio load + transcribe from the Susurro-owned directory, then
  delete. It took 157.6 s.

## ParakeetEngine and live engine switching (BEA-635)

- `ParakeetEngine: TranscriptionEngine` (`Sources/SusurroCore/ParakeetEngine.swift`)
  loads with `AsrModels.load(from: <Susurro models dir>/parakeet-tdt-0.6b-v2-coreml,
  version: .v2)` + `AsrManager.initialize` once at construction (warm), and
  transcribes 16 kHz mono Float32 via `AsrManager.transcribe(_:source: .microphone)`.
- `AsrManager` is a non-`Sendable` class with an async API; the engine is
  `@unchecked Sendable`, serializes every call with an `NSLock`, and bridges
  async to the protocol's sync `transcribe` with a detached task + semaphore.
- Buffers under 1 s (FluidAudio throws `invalidAudioData`) are padded with
  silence to 16,000 samples, so short push-to-talk taps still transcribe.
- **Load never downloads.** `AsrModels.load(from:)` silently re-downloads
  ~450 MB from Hugging Face into the directory's parent when files are missing
  (observed on 2026-11-04). The engine checks `AsrModels.modelsExist(at:version:)`
  first and throws `ParakeetEngineError.modelFilesMissing`, which the app shows
  as "Model load failed".
- `TranscriptionEngines.load(modelPath:engine:)` picks the engine from the
  catalog `EngineKind` (the app passes it) or infers it from the path
  (directory = Parakeet; the CLI relies on this, so
  `susurro-cli <parakeet dir> clip.wav` works).
- AppDelegate: the model menu lists every `available()` model, Parakeet
  included. Selecting one sets `activeModelID` and calls `loadEngine()`, which
  drops the current engine, loads the new one off-main and installs it. A
  generation counter discards a load that finishes after a newer selection, so
  fast whisper<->parakeet switching cannot leave the wrong engine active.
  Transcription errors are logged and shown as a "Transcription failed" toast
  instead of being swallowed.
- Verified 2026-11-04 (M2 Pro): `susurro-cli` on the 4 fixtures + a 0.3 s clip
  with Parakeet (cached load 19.8 s incl. Core ML compile, 0.07-0.12 s per clip);
  whisper path unchanged; an empty directory fails fast with no download.
  `swift test` 46/46 (4 new in `ParakeetEngineTests`). Hands-on menu switching
  in the running app is part of the BEA-641 dogfood.
