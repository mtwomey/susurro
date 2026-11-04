# Parakeet TDT v2 engine — feature plan

> Status: **built**, on branch `feature/parakeet-v2` (BEA-632 to BEA-638,
> docs in BEA-640). **Not yet released**: the board's hands-on dogfood test
> (BEA-641) comes first, then a single PR into `main` and a normal release
> with a Homebrew cask update (BEA-639). Companion to `ARCHITECTURE.md`
> (as-built structure) and `PLAN.md` (v1 historical design doc). Where this
> document and reality differ, they win, per this repo's usual convention.
>
> The sections below are kept in ticket order as the build log. "As built"
> right after the goal summarises what shipped on the branch and what
> differs from the spike.

Parent: BEA-631. Board decisions: BEA-630.

## Goal

Add NVIDIA Parakeet TDT 0.6B v2 (English, CC-BY-4.0, Core ML) as an
**additional** engine option via FluidAudio. `small.en` stays the default;
existing users' `activeModelID` is untouched. Custom vocabulary is out of scope.

## As built (summary)

| Area | What shipped | Where |
|---|---|---|
| Engine abstraction | `TranscriptionEngine` protocol (Sendable, warm, serialized, `kind`); `WhisperEngine` and `ParakeetEngine` conform; `TranscriptionEngines.load` picks by catalog `EngineKind` or path shape | `TranscriptionEngine.swift`, BEA-633/635 |
| Dependency | FluidAudio pinned `exact: "0.9.1"`, linked into `SusurroCore`; whisper flags made absolute + `-Xcc` swiftSettings | `Package.swift`, BEA-632/633 |
| Catalog | `parakeet-tdt-v2`, 443 MB, English, Apple Silicon only; 5 whisper models unchanged; `small.en` default; `activeModelID` key/values untouched | `ModelManager.swift`, BEA-634 |
| Download | Susurro's own `FileDownloader` over the HF tree listing, byte-weighted progress, staging dir + rename; FluidAudio's downloader is never used and its cache dir never written | BEA-634 |
| Load | `AsrModels.load(from:version: .v2)` behind a `modelsExist` guard (no silent re-download); first load ~20 s (Core ML compile), then sub-second | `ParakeetEngine.swift`, BEA-635 |
| Switching | Menu pick → `loadEngine()` off-main; generation counter drops stale loads; transcription errors surface as a toast | `AppDelegate.swift`, BEA-635 |
| Post-processing | Trigger-adjacent punctuation strip, mid-sentence recasing, quote-mark absorption; whisper-only `[...]` filter; Smart Spacing unchanged | `PostProcessor.swift`, `TranscriptFilter.swift`, BEA-636 |
| CLI / A/B | `susurro-cli --engine/--model/--post`; `scripts/ab_engines.py`; WER 2.4% (Parakeet) vs 11.4% (small.en), ~0.07 vs 0.25 s per clip | BEA-637 |
| UI | Model menu sectioned by engine with size + note in every state; Help text; About shows NVIDIA CC-BY-4.0 / FluidInference / FluidAudio credit | BEA-638 |
| Docs | `ARCHITECTURE.md` (engines & catalog section, code map, constraints), README (model options, attribution), this file | BEA-640 |

Differences from the spike and the original goal:

- The spike's `downloadAndLoad(version: .v2)` path was dropped. Susurro
  downloads into its own models directory and only ever calls `load(from:)`.
- The A/B corpus's industry-term clips are `say` stand-ins. Real-voice
  recordings are a BEA-641 step, so the 2.4% vs 11.4% figure is provisional
  until they're in.
- Still open: in-app memory footprint of Parakeet (spike RSS understates
  Core ML), on-screen review of the menu/About, hands-on engine switching
  (all BEA-641); whether to keep or delete the `parakeet-spike` target
  (BEA-639).

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

## Post-processing compatibility (BEA-636)

Corpus: the 4 fixtures plus 9 `say`-generated dictations covering every
default trigger, run through both engines with `susurro-cli --post <model>
<clips>` (prints `raw<TAB>processed` using bundled default rules).

- Parakeet keeps spoken triggers literal but glues its own punctuation on
  ("question mark?", "comma,", "colon. Buy"). `PostProcessor` step 1 now strips
  any of `, . ? ! ; :` *after* a trigger (before it, still only `, .`, so a real
  "?" ahead of "new line" survives) — no more "ready??".
- New step 0: a capitalised word after a mid-sentence trigger (`,` `;` `:`)
  plus `.?!` is lowercased ("Note colon. Buy milk" -> "Note: buy milk"); "I",
  I-contractions and multi-capital words (NASA, iOS) are kept.
- Quote triggers also eat adjacent quote marks; fixes a pre-existing whisper
  bug where `"quote hello there end quote"` became `" "hello there" "`.
- `TranscriptFilter.stripHallucinations(_:engine:)` is engine-aware: the
  `[...]` token strip is whisper-only (Parakeet has no such tokens), so
  dictated brackets survive on Parakeet. `TranscriptionEngine` gained `kind`.
- Smart Spacing needs no change: both engines return trimmed text, and the
  leading-space decision only looks at what Susurro last typed.
- Result: all 9 dictations produce the intended text on Parakeet; whisper
  differs only by mishearings ("comma" -> "Kama") and its own ITN, not by
  pipeline behaviour. Goldens: `Tests/SusurroTests/ParakeetPostProcessingTests.swift`.
  `swift test` 53/53.

## CLI engine selection and A/B accuracy harness (BEA-637)

- `susurro-cli --engine whisper|parakeet [--model <path>] clips...` selects the
  engine explicitly. Without `--model` it uses the app's managed model
  (small.en for whisper, `parakeet-tdt-v2` for Parakeet, falling back to
  FluidAudio's own cache dir); it never downloads. The old positional form
  `susurro-cli <model.bin | parakeet-dir> clips...` still works. `--post` is
  unchanged.
- `scripts/ab_engines.py` runs both engines over `Fixtures/ab/references.tsv`
  and prints the tables below (per-clip WER, totals, load/transcribe latency)
  plus every transcript. WER normalisation: lowercase, punctuation stripped
  (except inside numbers), whitespace split. Raw engine output, no
  `PostProcessor`.
- Corpus: the 4 existing `Fixtures/*.wav` (references hand-transcribed) and 6
  new `Fixtures/ab/*.wav` clips: industry terms (Dagster, dbt, Snowflake,
  Kubernetes, vLLM, LoRA, GGUF, llama.cpp, Kafka, Postgres, Terraform, Argo CD,
  Helm) and near-homophone negative controls (`control-dexter.wav`: "Dexter"
  only, must not become "Dagster"; `control-mixed.wav`: both words in one
  sentence).
- **Limit:** the new clips are macOS `say` (Samantha) stand-ins, not
  Matthew's voice. An agent can't record his voice unattended, so recording
  the same 6 sentences (same file names, overwrite) is a BEA-641 dogfood step.
  Rerun `scripts/ab_engines.py` afterwards. TTS audio is clean and
  well-enunciated, so the 0% rows on those clips are best-case numbers.

### Results (M2 Pro, release build, 2026-11-04; 3 runs, WER identical, latency from run 3)

| clip | words | whisper WER | parakeet WER |
|---|---|---|---|
| clip1.wav | 17 | 23.5% (4) | 0.0% (0) |
| clip2.wav | 26 | 19.2% (5) | 11.5% (3) |
| clip3.wav | 19 | 26.3% (5) | 0.0% (0) |
| smoke.wav | 23 | 17.4% (4) | 0.0% (0) |
| terms-dagster.wav | 13 | 0.0% (0) | 0.0% (0) |
| control-dexter.wav | 12 | 0.0% (0) | 0.0% (0) |
| terms-llm.wav | 17 | 0.0% (0) | 0.0% (0) |
| terms-kafka.wav | 12 | 0.0% (0) | 0.0% (0) |
| terms-infra.wav | 15 | 0.0% (0) | 0.0% (0) |
| control-mixed.wav | 12 | 8.3% (1) | 8.3% (1) |
| **total** | 166 | **11.4%** (19) | **2.4%** (4) |

| engine | load (s) | transcribe total (s) | mean per clip (s) | audio (s) | realtime |
|---|---|---|---|---|---|
| whisper | 0.27 | 2.49 | 0.25 | 83.0 | 33x |
| parakeet | 0.24 | 0.69 | 0.07 | 83.0 | 120x |

Load time is a warm cache (Core ML already compiled; the first-ever Parakeet
load takes ~20 s, see BEA-635). Latency runs 1-2: whisper 2.61/2.53 s, Parakeet
0.78/0.69 s total transcribe time.

### Findings

- Parakeet: 4 errors in 166 words (2.4%) vs whisper small.en 19 (11.4%).
  Parakeet was never worse than whisper on any clip, at about 3.5x lower
  transcribe latency (0.07 vs 0.25 s per clip).
- Most of whisper's errors on the existing corpus are formatting and
  dictation-relevant: it turns spoken "quote ... end quote, comma" into
  quote marks and drops the "comma" (clip3, 5 errors), and writes times as
  "9.45am" / "3.30 pm" (clip1, smoke). Its real mishears: "unique socket",
  "launch_dp list", "wispercpp" (clip2).
- Parakeet's only misses on the existing corpus are clip2 jargon ("Launch DD
  list", "whisper CPP"), which the deferred vocabulary feature would target.
- Negative controls pass on both engines: "Dexter" is never rewritten to
  "Dagster" or the reverse, and the mixed sentence keeps both. Both engines
  write "Dagster daemon" as "Dagster demon"; that sentence is pinned as a
  fixture for the vocabulary feature.
- On TTS audio both engines get every industry term right (casing aside:
  "DAGSTER", "LoRa", "LLAMA.cpp"; WER ignores case). This is the main thing
  the real-voice recordings in BEA-641 need to confirm.
- Core ML's E5RT runtime prints a one-off `zero shape error` diagnostic to
  stdout on Parakeet's first inference in a process. The returned transcript
  is correct and the app ignores stdout; the harness strips the line.

## Menu, Help and About (BEA-638)

- Model menu is sectioned by engine: `ModelManager.menuSections()` groups
  `available()` in `EngineKind` order, and AppDelegate adds an
  `NSMenuItem.sectionHeader` per group ("Whisper (whisper.cpp)", "NVIDIA
  Parakeet (Apple Silicon)") with a separator between. Intel Macs get no
  empty Parakeet section.
- Every entry shows id, size and note in all states, including "download"
  and "downloading N%", so a model can be judged before downloading it.
  Parakeet's note is "English, most accurate". large-v3-turbo's note is now
  "most accurate Whisper, multilingual" so the two notes don't contradict.
- HelpWindow "Model" describes both engine groups, the download/progress
  behaviour and Apple Silicon gating. "About Susurro" mentions the GitHub
  link and the Parakeet licence credit.
- About shows `ModelManager.parakeetAttribution` (NVIDIA, CC-BY-4.0,
  FluidInference Core ML conversion, FluidAudio Apache 2.0) whatever model
  is active.
- Tests: `menuSectionsGroupByEngine`, `parakeetMenuNoteAndAttribution`;
  `make test` 55/55. The menu and About need an on-screen look in BEA-641.

## End-of-sentence punctuation (BEA-643) — decision: two-pass terminal mark

Problem: Parakeet drops the final ?/. when the buffer ends at the last word
(push-to-talk), so one-sentence dictations had no end punctuation. Trailing
silence restores the mark but changes the body, non-monotonically with pad length.

Bar (board): per-clip WER (punctuation-insensitive) <= the unpadded baseline on
EVERY clip, no new words and no number/time formatting changes (normalised tokens
identical to baseline), terminal ?/. correct on >= 90% of push-to-talk clips.

Harness: `scripts/pad_sweep.py` runs susurro-cli over Fixtures/ab (10 clips) +
Fixtures/punct (16 `say` clips, 8 questions / 8 statements, trailing silence
trimmed to 10 ms after the last word) once per candidate, using the dev-only
`SUSURRO_DEV_PAD_MS` / `SUSURRO_DEV_PAD_ALIGN` / `SUSURRO_DEV_PAD_NOISE` env vars
in susurro-cli (no rebuild per value). Fresh unpadded baseline (87e1ff6):
ab_engines.py Parakeet 2.4% (4/166), identical to BEA-637; 0/16 terminal marks.

Selected rows (full 160-row table: run the script; 2026-11-04, M2 Pro):

| candidate | WER errors (26 clips) | per-clip WER regressions | token changes vs baseline | terminal ?/. | meets bar |
|---|---|---|---|---|---|
| baseline | 5 | - | 0  | 0/16 (0%) | no |
| a:zero 400ms | 12 | clip1.wav 0->3, clip2.wav 3->5, smoke.wav 0->2 | 3 clip1.wav, clip2.wav, smoke.wav | 14/16 (88%) | no |
| a:zero 450ms | 11 | clip1.wav 0->2, clip2.wav 3->5, smoke.wav 0->2 | 3 clip1.wav, clip2.wav, smoke.wav | 16/16 (100%) | no |
| a:zero 500ms | 12 | clip1.wav 0->2, clip2.wav 3->5, smoke.wav 0->3 | 3 clip1.wav, clip2.wav, smoke.wav | 16/16 (100%) | no |
| a:zero 1000ms | 12 | clip1.wav 0->2, clip2.wav 3->5, smoke.wav 0->3 | 3 clip1.wav, clip2.wav, smoke.wav | 16/16 (100%) | no |
| a:zero 1500ms | 10 | clip1.wav 0->2, clip2.wav 3->5, smoke.wav 0->1 | 3 clip1.wav, clip2.wav, smoke.wav | 16/16 (100%) | no |
| b:zero 1000ms align1280 | 12 | clip1.wav 0->2, clip2.wav 3->5, smoke.wav 0->3 | 3 clip1.wav, clip2.wav, smoke.wav | 16/16 (100%) | no |
| b:noise0.0003 1000ms | 12 | clip1.wav 0->2, clip2.wav 3->5, smoke.wav 0->3 | 3 clip1.wav, clip2.wav, smoke.wav | 16/16 (100%) | no |
| b:noise0.0003 1500ms | 9 | clip1.wav 0->2, clip2.wav 3->5 | 2 clip1.wav, clip2.wav | 16/16 (100%) | no |
| d:fallback | 5 | - | 0  | 16/16 (100%) | YES |
| c:two-pass zero 400ms | 5 | - | 0  | 14/16 (88%) | no |
| c:two-pass zero 450ms | 5 | - | 0  | 16/16 (100%) | YES |
| c:two-pass zero 1000ms | 5 | - | 0  | 16/16 (100%) | YES |
| c:two-pass zero 1500ms | 5 | - | 0  | 16/16 (100%) | YES |

- (a) Zero pad: no length from 50-1500 ms meets the bar. Every length changes clip1/clip2
  (and smoke at most lengths); marks need >= 450 ms.
- (b) Frame-aligned (1280-sample) pads and low-level noise instead of zeros behave like (a).
  No pad shape tested is body-neutral. Causes (verified):
  1. Per-utterance feature normalisation. Parakeet's preprocessor (NeMo
     `normalize: per_feature`, baked into FluidAudio's Preprocessor.mlmodelc:
     length mask + reduce_sum + sqrt + div) rescales every mel band by the mean/std
     of the whole valid buffer. Padding is counted as valid audio, so it shifts the
     features of the speech itself: on smoke.wav the speech-region mel moves by a
     mean 0.016 / 0.075 / 0.139 / 0.197 normalised units at 100 / 500 / 1000 /
     1500 ms pad (`scripts/mel_norm_probe.py`; needs `uv run --with coremltools
     --with numpy`). FluidAudio's own zero-fill to 15 s sits beyond `audio_length`
     and is masked, which is why it is harmless and ours is not. The encoder's
     full-utterance attention also sees the new frames.
  2. The 15 s window. FluidAudio transcribes <= 240,000 samples in one window and
     longer audio through overlapping chunks (ChunkProcessor). clip1-3 are exactly
     15.00 s, so any pad moved them onto the chunked path; that, not the silence,
     is what changed clip1/clip2. Short push-to-talk clips kept their words under
     every pad; smoke.wav (9.8 s) is the cause-1 case.
- (d) Question-word heuristic: passes on this set, but guesses (imperatives such
  as "Do the dishes" would get "?"); the model's own judgment is preferred.
- (c) Two-pass meets the bar at every pad from 450 to 1500 ms: the body is the
  unpadded transcript byte-for-byte, only a final ?/./! is taken from a padded
  pass, and the second pass runs only when the first has no final mark.

Shipped: (c) with 1000 ms (middle of the passing range), in
`ParakeetEngine.transcribe` (`withTerminalMark`, unit-tested). Cost: one extra
Parakeet pass on utterances without a final mark (~0.1 s on these clips; Parakeet
runs ~100x real time). Verified end to end with the shipped engine and no env
vars: 26/26 clips token-identical to baseline, 16/16 terminal marks. Limit: `say`
voices are a proxy for Matthew's voice; the dogfood test is the real check.

### Revised decision (board review): single pass with 2 s of trailing silence

The two-pass bar above scored candidates against the *unpadded output*. Scored
against what was actually said (`scripts/pad_eval.py`, clips trimmed to the last
word), the unpadded push-to-talk input is itself the weak case. The model was
trained on audio with trailing silence, and cut-off audio formats worse.

Matthew's own push-to-talk recordings (Fixtures/voice, 14 clips; v08 excluded,
misread; recordings not committed):

| pad | reference errors | clips better | clips worse | final ?/. |
|---|---|---|---|---|
| 0 (two-pass) | 31 | - | - | 14/14 |
| 1000 ms | 29 | 2 | 1 | 14/14 |
| 1500 ms | 14 | 5 | 1 | 14/14 |
| 1750 ms | 10 | 5 | 1 | 14/14 |
| **2000 ms** | **10** | **5** | **0** | **14/14** |
| 2500 ms | 14 | 4 | 0 | 14/14 |
| 3000 ms | 10 | 5 | 0 | 14/14 |

Typical change on his voice: "three thirty PM on january twenty second" became
"3:30 p.m. on January 22nd", and "six fifteen AM" became "6:15 a.m.". Synthetic
`say` set + trimmed fixtures (40 clips): 50 -> 23 errors at 2 s; 1 clip worse
("April 1st" -> "April 1").

Shipped: `ParakeetEngine.trailingSilenceSamples = 32_000` (2 s), capped so an
utterance never crosses FluidAudio's 15 s single window
(`trailingPad(for:)`). When the cap shortens the pad and the final mark is
missing, the two-pass mark fallback runs. Verified with the shipped build and
no env vars: voice set 10 errors and 14/14 marks; 40-clip set 23 errors and
40/40 marks; ab_engines Parakeet 2.4%, per clip identical to the baseline
(clip1-3 are 15.00 s, so they get no pad).
