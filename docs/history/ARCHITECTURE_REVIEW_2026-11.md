# Susurro architecture review (origin/main 2009936, 0.2.0-beta.2)

Review only (BEA-660). No code changes are on this branch. Line numbers refer to `origin/main` at 2009936.

## Status at 9d0398b (2026-11-06)

Added at the post-refactor closeout (BEA-682). Refactors R0–R6 are merged;
main 9d0398b, CI green, 224/224 tests passing locally. The finding text below
is unchanged from the review (commit a9a1b9f on the deleted branch
`review/architecture-2026-11`); its line numbers refer to 2009936.

| Finding | Status | Closed by / tracked in |
|---|---|---|
| F1 `transcribeAndInsert` hotspot, untestable | closed | R2 da5579f (BEA-664: DictationPipeline + InsertPlan in SusurroCore), R4 f7c370c (BEA-666: DictationController; AppDelegate 1294 → 321 lines) |
| F2 Hands-free cancel doesn't cancel an in-flight chunk | closed | R1 5ba6f16 (BEA-663: SessionGate re-checked before joiner.accept and at insert; GatedChunk cancel-race test) |
| F3 No serial insertion queue | closed | R3 cc839c9 (BEA-665: one InsertionQueue for PTT + hands-free, InsertExecutor) |
| F4 Pipeline duplicated in the CLI | closed | R2 da5579f (BEA-664: susurro-cli runs DictationPipeline; golden hands-free replay) |
| F5 250 ms AX cap is not a cap | closed | R1 5ba6f16 (BEA-663: CappedRead) |
| F6 Engine extension cost spread out | closed | R6 9d0398b (BEA-667: EngineCatalog, EngineCapabilities, catalog-driven loader) |
| F7 Model swaps keep two engines resident | open | R8 (model-swap memory policy), only if memory complaints come in |
| F8 Join latency not measured | closed | R1 5ba6f16 (BEA-663: StageTimings ms_ax/ms_transcribe/ms_join/ms_insert in text-handling.log); the structured per-dictation record is part of R7 |
| F9 Config sprawl | closed | R4 f7c370c (BEA-666: Settings façade + Tuning) |
| F10 No CI | closed | R5 d87ca79 (BEA-662: GitHub Actions build + swift test; release stays local) |
| F11 Docs drifted | closed | R0 5a90491 (BEA-661: plans to docs/history/, ARCHITECTURE.md for 0.2.0); drifted again over R2–R6, refreshed by BEA-682 (this commit) |
| F12 Dead code (HAL/SCK recorders, parakeet-spike) | closed | R0 5a90491 (BEA-661) |
| F13 PostProcessor re-reads rules.json per call | won't-do | By design (live reload); cost is tiny. Add an mtime check only if it shows up in a profile |
| F14 Logging (NSLog, TextHandlingLog) | closed | R7 (BEA-683): NSLog/`slog` replaced by `os.Logger` (SusurroCore Logging.swift, subsystem com.mtwomey.susurro, 4 categories); one `DictationRecord` per dictation with no text fields. text-handling.log kept (docs read coverage from it), now written from the same record |
| F15 Concurrency annotations | won't-do | No action needed; `FocusedFieldReader.enabledPIDs` is still `nonisolated(unsafe)` behind a lock (correct). Engines stay lock-serialised, not actors |
| F16 Branches and worktrees | closed | R0 5a90491 (BEA-661: 11 merged branches and stale worktrees removed). Remaining remote branches: the 2 kept unmerged ones (`experiment/parakeet-trailing-silence`, `prototype-voice-processing-aec`) and `spike/latch` (BEA-678); `review/architecture-2026-11` deleted by BEA-682 |
| F17 Build and release | won't-do | No action needed; release and signing stay local (docs/releasing.md), CI has no signing steps |

Refactor plan: R0–R6 done (R0 5a90491, R1 5ba6f16, R2 da5579f, R3 cc839c9,
R4 f7c370c + b1f215b, R5 d87ca79, R6 9d0398b). R7 done in BEA-683 (os.Logger + per-dictation record); R8 is open.

Also open: the wall-clock `CappedRead` test in DictationTimingTests failed
once on CI at the R4 merge (f7c370c, CI run 42176342630) when the CPU-bound
HandsFreeSessionTests starved it on the 3-core runner. b1f215b mitigated it
(fixture loaded once, those tests serialized). Treat it as a flake to watch:
if it fails again, widen its margins or make it clock-free.

The current architecture is described in `docs/ARCHITECTURE.md`.

## Verdict

The architecture is mostly sound. The core logic is in good shape: engines sit behind a small protocol, and hands-free decisions are in pure, tested types (`HandsFreeMachine`, `PauseSegmenter`, `HeldMarkJoiner`/`HandsFreeJoin`). Text handling is a pure stage (`TextHandlingStage`, `InsertContext.resolve`). SusurroCore has 154 unit tests.

The problem is in one place. Everything that turns a transcript into keystrokes is a single 190-line closure, `AppDelegate.transcribeAndInsert` (AppDelegate.swift:753-943). It is shared by two trigger modes, and it uses ad-hoc concurrency. The three new directions all meet there, which is where the bugs and the growth cost will come from.

The fix is one medium-sized, behaviour-preserving extraction: a `DictationPipeline` in SusurroCore, plus a serial insertion queue. That fix is worth doing **now**, before a third engine, more app bridges or another trigger mode. Most other work is small cleanup. A full rewrite (modularising into more packages, actors everywhere, a plugin system) is **not worth it**.

## 1. Current-state map

```
Targets (Package.swift)
  CWhisper        C shim over vendor/whisper.cpp (submodule f049fff, v1.8.5-95) + unsafeFlags link paths (Package.swift:6-30, 47, 62)
  SusurroCore     library, no AppKit UI: engines, catalog/downloads, capture, post-processing, text-handling, hands-free logic
  Susurro         the .app (AppKit): AppDelegate + panels + hotkey + AX reader + app bridges + injector
  susurro-cli     file transcription + --post pipeline + hands-free join replay (duplicates app logic, see F4)
  parakeet-spike  BEA-632 feasibility harness (dead weight now)
  SusurroTests    154 tests over SusurroCore
External: FluidAudio exact 0.9.1 (Package.swift:39). Build: Makefile (whisper -> swift build -> hand-assembled .app -> codesign). No CI.

Runtime flow (both triggers)
  HotkeyMonitor (CGEventTap, HotkeyMonitor.swift:92)
     │ PTT down/up                     │ latch key -> HandsFreeMachine (pure)
     ▼                                 ▼
  AudioRecorder (AVAudioEngine, @unchecked Sendable + NSLock)
     │ stop() -> all samples           │ 100 ms Timer -> takeAvailable() -> PauseSegmenter cuts
     │                                 │ hfDispatch -> hfInsertChain (serial Task chain, generation guard)
     ▼                                 ▼
  AppDelegate.transcribeAndInsert (AppDelegate.swift:753)  <-- single convergence point
     ├─ parallel: FocusedFieldReader.read (AX / AppBridges, "250 ms cap")
     ├─ Task.detached: engine.transcribe -> TranscriptFilter -> PostProcessor (re-reads rules.json) -> optional LLM cleaner
     ├─ hands-free only: HeldMarkJoiner.accept on MainActor; on needsJoin, SECOND transcribe of a joint clip (:810)
     └─ MainActor.run: app-switch -> clipboard (:835) | InsertContext.resolve | TextHandlingStage (:870)
                       | shown-mark retract/Backspace (:909) | TextInjector.type (:913) | DictationMemory | clipboard copy
Model lifecycle: ModelManager catalog (static, ModelManager.swift:75) -> TranscriptionEngines.load (switch on EngineKind)
                 -> AppDelegate.loadEngine with engineGeneration (:458-510)
Settings: 5 UserDefaults keys + activeModelID, rules.json, plus compile-time constants (PauseSegmenter.Config, HandsFreeMachine init, AX cap)
```

What is testable without the app: engines (with model files), catalog and download, PostProcessor, filters, the TextHandling stage, context resolution, DictationMemory, PauseSegmenter, HandsFreeMachine and HandsFreeJoin. What is not testable: the composition of those pieces, meaning ordering, which branch is taken (fresh / join / shown-mark / app-switch), clipboard fallbacks, generation and cancel handling, AX timing and insertion. That untestable part is exactly where the three new features interact.

## 2. Findings, ranked (impact × urgency)

### High

**F1. `transcribeAndInsert` is the single hotspot, and it is untestable** (AppDelegate.swift:753-943)
- One closure does seven things: capture snapshot, transcription, filter/post/LLM, the hands-free join (including a second engine call), context resolution, the text-handling stage, the shown-mark Backspace protocol, insertion, memory bookkeeping and clipboard policy.
- It passes state between three isolation hops through loose locals (`joinText`, `joinAfter`, `prevShown`, `prevMark`, `decision`, :832-834).
- New features cost more each time. Each beta added another `if hfChunk` / `if prevShown` branch.
- A new trigger (e.g. a toggle mode or a "re-dictate selection" command), a new insertion method (paste, AX `setValue`) or a new transform would all have to edit this closure.
- Impact: high. Urgency: high, because each upcoming feature lands here.

**F2. Hands-free cancel does not cancel an in-flight chunk** (likely bug; verify with a test)
- `hfEnd(insert: false)` bumps `hfGeneration` (:1078).
- The generation is checked only before a chunk *starts* (:1043). The final `MainActor.run` insert block (from :830) never re-checks it.
- So a chunk that is mid-transcription when the user presses Esc can still be typed after "Hands-free discarded".
- It can also call `hfJoiner.accept` (:800) on a joiner that was just `discard()`ed, or on the fresh joiner of a *new* session if one was latched quickly. In that case it leaks a held mark across sessions.
- Impact: medium-high (wrong text typed after the user said "discard"). Urgency: high, and the fix is cheap.

**F3. There is no serial insertion queue across triggers or within PTT**
- Each PTT release spawns an independent `Task.detached` (:767). `WhisperEngine`/`ParakeetEngine` serialise `transcribe` with an `NSLock`, which is not FIFO. The optional `await cleaner.clean` and the AX read also add variable latency.
- So two quick PTT dictations can insert out of order.
- A PTT dictation started right after a hands-free stop runs alongside the pending `hfInsertChain` (:1066). Both mutate `dictationMemory`, and the hands-free tail still types its held mark (:1070-1075).
- Only hands-free has ordering (the Task chain). PTT has none, and the two don't coordinate.
- Impact: medium (rare, but it corrupts text). Urgency: medium-high. The pipeline extraction (R2) fixes it structurally.

**F4. The pipeline is duplicated in the CLI** (susurro-cli/main.swift:110-186)
- The CLI re-implements filter → PostProcessor and the hands-free chunk/joint-clip/decide loop (:116-160) so that `scripts/handsfree_join_eval.py` can replay it.
- The evaluation harness can therefore pass while the app diverges. The app's join (:806-826) and the CLI's join are separate code paths.
- Impact: medium (eval results stop being trustworthy). Urgency: medium. Fixed for free by R2.

### Medium

**F5. The 250 ms AX cap is probably not a cap** (FocusedFieldReader.swift:20-36)
- `withTaskGroup` implicitly awaits *all* child tasks before it returns, and the reader child is a non-cancellable `DispatchQueue` continuation. So `group.cancelAll()` cannot make the function return early.
- The effective bound is AX's own 0.2 s messaging timeout *per call* (:47), and `readNow` makes several calls, plus any app-bridge time.
- It overlaps with transcription, so it is usually hidden. With Parakeet (~0.07-0.12 s) the AX read can become the critical path.
- Fix: return through an unstructured race (a continuation resumed once by whichever finishes first). Also add the read latency to TextHandlingLog.
- Impact: medium (latency). Urgency: medium. Effort: small.

**F6. Engine extension cost is moderate and spread out**
- Adding a third engine (Qwen3-ASR or Apple SpeechTranscriber) touches:
  - `EngineKind` and its display names (ModelManager.swift:5-17)
  - the catalog entries and `isDirectory` (:49, :75-96)
  - the download switch (:230)
  - `TranscriptionEngines.load` (TranscriptionEngine.swift:37-49)
  - `kind(ofPath:)`, which can't tell two directory engines apart (:45-48)
  - `TranscriptFilter` rules keyed on the engine
  - `InsertContext.engine`, used for Parakeet's punctuation tolerance (ContextProviders.swift:282)
  - CLI `managedPath` (susurro-cli:58)
  - the menu sections
- That is about 8 places in 6 files. It is fine for engine #3. It hurts at #4, or with an engine that needs streaming, a language setting or a vocabulary prompt.
- The `TranscriptionEngine` protocol itself is good (warm, serialised, Sendable). It lacks capability flags (`doesITN`, `emitsPunctuation`, `supportsPrompt`, `streaming`), so engine-specific behaviour is instead an `engine == .parakeet` check at each call site.
- Impact: medium. Urgency: medium. Do it as part of the third-engine ticket, not before.

**F7. Model swaps keep two engines resident**
- In-flight tasks capture the old `engine` (:756) while `loadEngine` builds the new one (:485). Peak memory during a switch is old + new: about 600 MB for small.en plus Parakeet's Core ML.
- This is acceptable today, but it should be a deliberate policy, documented and logged, rather than a side effect.
- Impact: low-medium. Urgency: low.

**F8. Join latency doubles transcription work**
- Every hands-free `needsJoin` re-transcribes a joint clip (:810), so per-chunk cost is about 2× engine time on top of the AX read.
- That is fine with Parakeet and noticeable with large whisper models. It isn't measured anywhere.
- Add per-stage timings (transcribe, join, AX, insert) to a structured log line.
- Impact: medium for whisper users. Urgency: low-medium.

**F9. Config sprawl is modest but invisible**
- There are 6 UserDefaults keys, accessed through ad-hoc computed properties in AppDelegate (:33-45), plus `activeModelID` in ModelManager (:135).
- Tuning lives in code defaults:
  - `PauseSegmenter.Config`: minPause 1.0, maxSegment 25, thresholds (PauseSegmenter.swift:12-28)
  - `HandsFreeMachine`: 7,200 s / 60 s / 10 s (HandsFreeMachine.swift:90)
  - AX cap 250 ms and messaging timeout 0.2 s
  - `slowLoadThreshold` 1.5 s
- This isn't a problem yet. A `Settings` struct (one typed façade over UserDefaults plus a `Tuning` struct carrying these constants) would make the pipeline testable and allow a hidden "advanced" defaults domain without UI.
- Impact: low-medium. Urgency: low. Do it as part of R2.

**F10. No CI**
- No `.github/` exists. `swift test` (154 tests) runs only when someone remembers `make test`.
- A whisper.cpp-submodule-plus-unsafeFlags build makes CI a little fiddly, but a macOS runner with `make whisper && swift test` is about 1 hour of work.
- Impact: medium. Urgency: medium (cheap insurance before refactors).

### Low

**F11. The docs have drifted**
- docs/ARCHITECTURE.md says "as of v0.1.9 plus the Parakeet…" (:5). It has no section on hands-free, PauseSegmenter, the joins and shown-mark Backspace, or the text-handling stage, AX reader and AppBridges.
- Its "One dictation, end to end" section (:122-155) describes PTT only.
- There are 14 docs, several of them finished plans (PLAN, PARAKEET_PLAN, SMART_SPACING_PLAN, VOCABULARY_PROMPT_PLAN, ECHO_CANCELLATION_PLAN). They should move to `docs/history/`.

**F12. Dead code**
- `HALAudioRecorder.swift` (172 lines) and `SCKAudioRecorder.swift` (138 lines) are unused. They are referenced only in a comment (AppDelegate.swift:20-22).
- The `parakeet-spike` target (Package.swift:87-89) is unused.
- That is about 350 lines compiled into every build. Delete them; git history keeps the evaluation.

**F13. PostProcessor re-reads rules.json on every call** (PostProcessor.swift:50, 78)
- This is by design ("live reload for free"). With hands-free joins it runs twice per chunk.
- The cost is tiny (a small file). It is noted only so nobody "optimises" it blindly. An mtime check would be enough if it ever shows up in a profile.

**F14. Logging**
- `slog` is NSLog (AppDelegate.swift:8-10), and the unified log doesn't keep it.
- TextHandlingLog opens and appends a file per dictation with its own rotation (TextHandlingLog.swift:10-32), on the main actor inside the insert block.
- The I/O cost is negligible. Moving to `os.Logger` with a subsystem, plus a single structured per-dictation record (stages, timings, source and provider, no field text), would replace both and make F8 measurable.

**F15. The concurrency annotations are reasonable**
- `@unchecked Sendable` appears on 8 types, each lock-guarded and documented.
- `FocusedFieldReader.enabledPIDs` is `nonisolated(unsafe)` behind an NSLock (:17-18). It is correct but could be `Mutex`/`OSAllocatedUnfairLock`.
- No action is needed beyond R2. Don't convert engines to actors: the lock-serialised synchronous `transcribe` is the right fit for C and Core ML backends.

**F16. Branches**
- There are 13 non-main remote branches. Eleven are merged into main and can be deleted: dev-flag-legacy-model-seed, about-github-link, colon-semicolon-no-space-before, github-menu-item, hands-free, handsfree-joins, handsfree-showmark, parakeet-number-rules, parakeet-v2, smart-spacing, text-handling.
- Two are unmerged: `experiment/parakeet-trailing-silence` (2026-11-04) and `prototype-voice-processing-aec` (2026-07-15). Keep them or tag them as archives.
- Five local worktrees (`susurro-handsfree*`, `-parakeet`, `-texthandling`) point at merged branches and can be removed.

**F17. Build and release are OK**
- FluidAudio is pinned exactly (good).
- The whisper.cpp submodule plus `unsafeFlags` blocks SusurroCore from being consumed as a dependency by other packages. That is irrelevant for an app.
- The Makefile release and cask flow is documented in docs/releasing.md.
- Risk: signing and notarisation are local-only. If CI is added, keep release local.

## 3. Recommended target architecture

Keep the module layout (Core + App). Add one explicit seam:

```
Trigger (PTT | HandsFree | future)  ──► DictationSession: owns capture + segmentation, emits Utterance(samples, target app, chunk info, generation)
                                          │
                                          ▼
                     DictationPipeline (SusurroCore, pure/async, testable)
                       transcribe(engine) → filter(engine caps) → postProcess(rules) → [LLM clean]
                       → join step (HeldMarkJoiner + optional joint re-transcribe)
                       → InsertPlan { text, deleteBackward, clipboardFallback, markShown, memoryUpdate }
                                          │
                                          ▼
                     InsertionQueue (@MainActor, single serial FIFO, generation/cancel-aware)
                       resolve InsertContext (FieldReader, AppBridges, DictationMemory) → TextHandlingStage
                       → Inserter protocol (KeystrokeInserter today; Paste/AX later) → bookkeeping
```

- `EngineKind` gains an `EngineCapabilities` value (punctuation, ITN, prompt support, streaming). `TranscriptFilter` and context resolution read the capabilities instead of `== .parakeet`. Catalog entries carry a loader closure or factory key, so adding an engine is one file plus one catalog entry.
- AppDelegate shrinks to menu, permissions and wiring (target under 500 lines). Model lifecycle moves to an `EngineController` (load, generation, state, toasts). Hands-free plumbing (`hf*` vars, :47-63, :945-1094) moves to a `HandsFreeSession`.
- The CLI drives the same `DictationPipeline` with a fake inserter. That gives the eval harness, and a fixture-driven integration test, real coverage of the app path.

## 4. Sequenced refactor plan

Each step ships independently and preserves behaviour.

| # | Step | Call | Effort | Test strategy |
|---|------|------|--------|---------------|
| R0 | Housekeeping: delete the 11 merged branches and stale worktrees; delete HAL/SCK recorders and `parakeet-spike`; move finished plans to `docs/history/`; refresh ARCHITECTURE.md (hands-free, text handling) | **Now** | S (½ day) | `swift build`, `swift test`, `make app` smoke |
| R1 | Fix F2: re-check the generation inside the insert block, and give the joiner a session id; fix F5: make the AX cap real; add per-stage timing to the log | **Now** | S (½–1 day) | Unit test for the cancel race via an injectable delay; log-line assertion; manual Esc-mid-chunk check |
| R2 | Extract `DictationPipeline` (transcribe → filter → post → clean → join → `InsertPlan`) into SusurroCore; the CLI uses it (removes F4) | **Now** | M (2–3 days) | Golden tests: replay `Fixtures/punct`, `Fixtures/ab` and the hands-free eval through the pipeline with a fake engine and fixture transcripts; the A/B CLI output must be byte-identical before and after |
| R3 | `InsertionQueue`: a single serial FIFO for PTT and hands-free, cancel-aware; an `Inserter` protocol around TextInjector; move the clipboard and secure-input policy into it (fixes F3) | **Now** (right after R2) | M (1–2 days) | Fake inserter + fake frontmost-app provider: ordering, app switch → clipboard, shown-mark retract, secure input |
| R4 | Split AppDelegate: `EngineController`, `HandsFreeSession`, `Settings`/`Tuning` façade (F9) | **Later** (next feature cycle) | M (2 days) | Existing tests + HandsFreeSession tests with a fake recorder feeding fixture audio |
| R5 | CI: GitHub Actions macOS runner, cached whisper build, `swift test`; release stays local | **Now** (before R2 if possible) | S (≈1 h–½ day) | Green run on a PR |
| R6 | `EngineCapabilities` + catalog-driven loader (F6) | **Later**: with the 3rd-engine ticket | S–M (1 day) | Catalog tests; filter tests parameterised by capabilities |
| R7 | `os.Logger` + a structured per-dictation record replacing NSLog and TextHandlingLog (F14) | Later | S | Manual |
| R8 | Explicit model-swap memory policy (drop the old engine after in-flight work drains) (F7) | Later / only if memory complaints come in | S | Memory check in Activity Monitor during a switch |
| — | Split into more SwiftPM packages, actor-ify engines, plugin system for transforms | **Not worth it** | — | — |

The recommended order is R0, R5, R1, then R2 and R3 together, then R4/R6 when the next engine or trigger lands. That is roughly 5–7 focused days for the "now" set.

## 5. What is fine and should stay

- The `TranscriptionEngine` contract and lock-serialised engines.
- The pure, tested hands-free state machine, segmenter and joiner.
- The `ContextProvider` / `InsertContext.resolve` design, with field text never logged.
- The exact FluidAudio pin, the Makefile release flow, and keeping SusurroCore free of AppKit UI.
