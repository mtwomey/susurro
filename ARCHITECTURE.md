# Susurro — Architecture (as built)

Companion to `PLAN.md` (the historical design document — read it for *why*
decisions were made, including investigated-and-rejected alternatives).
This file describes what actually exists, as of v0.1.3.

## Overview

Single-process macOS menu bar app (Swift 6, strict concurrency, SwiftPM — no
Xcode project). Hold a key → record mic to memory → transcribe in-process with
whisper.cpp → post-process text → type into the focused app via CGEvents.
No daemons, sockets, temp files, or network dependency after model download.

## Targets & code map

```
Package.swift               SPM manifest; whisper linker flags defined once, shared
Sources/
  CWhisper/                 C shim exposing vendor whisper.h to Swift (empty .c + header)
  SusurroCore/              Library shared by app, CLI, tests
    WhisperEngine.swift       whisper.cpp C API wrapper; model loaded once, stays warm;
                              transcribe() internally serialized (ctx not reentrant)
    AudioRecorder.swift       PRODUCTION capture: AVAudioEngine input tap → 16kHz mono
                              Float32 in RAM; peak-level callback; config-change
                              (mic unplugged) interruption callback
    HALAudioRecorder.swift    UNUSED alternative (raw CoreAudio IOProc) — kept from the
                              mic-pill investigation; see PLAN.md
    SCKAudioRecorder.swift    UNUSED alternative (ScreenCaptureKit mic capture) — kept;
                              avoids mic pill but adds screen-recording pill + 75-160ms
                              start latency; see PLAN.md
    AudioFileLoader.swift     any audio file → 16kHz mono Float32 (used by CLI/tests)
    AudioResampler.swift      shared mono resample helper
    ModelManager.swift        model catalog (5 ggml models), HuggingFace download with
                              progress (FileDownloader: URLSession delegate wrapped in
                              async/await), active-model selection, legacy-path seed
    PostProcessor.swift       verbal punctuation pipeline; loads rules fresh from user
                              rules.json EVERY call (= live reload); falls back to
                              DefaultRules on missing/corrupt file
    DefaultRules.swift        default rules.json EMBEDDED as a Swift string. Deliberate:
                              SPM Bundle.module resources DO NOT WORK in hand-assembled
                              .app bundles (crashed 0.1.0 on all non-dev machines)
    TranscriptFilter.swift    strips whisper hallucination tokens ([BLANK_AUDIO] etc.)
    SpacingRule.swift         Smart Spacing decision logic: add a leading space whenever
                              resuming a dictation, unless the text before the cursor
                              already ends in whitespace (avoids doubling up). Pure
                              Foundation — unit-tested
    DictationMemory.swift     Smart Spacing's state: remembers the last character Susurro
                              itself typed and which app (pid) it typed into. No
                              Accessibility dependency — see SMART_SPACING_PLAN.md for why
                              an earlier AX-read design was abandoned
    TranscriptCleaner.swift   optional AI cleanup via FoundationModels (macOS 26 +
                              Apple Intelligence); guided generation (@Generable) so the
                              model can't emit preamble; <6-word skip; sanity-check
                              fallback. TextCleaning protocol = availability-agnostic
                              handle for macOS 15 callers
  Susurro/                  Menu bar app
    main.swift                NSApplication bootstrap, .accessory activation policy
    AppDelegate.swift         CENTRAL COORDINATOR: menu construction, permission flows,
                              model menu, PTT wiring, dictation pipeline assembly,
                              SIGUSR1 debug hook, notifications
    HotkeyMonitor.swift       CGEventTap; PTTKey = modifier (flagsChanged) or regular
                              key (keyDown/up, swallowed); auto re-enables disabled taps
    TextInjector.swift        CGEvent unicode typing, 18-UTF16-unit chunks, Return for
                              newlines
    OverlayPanel.swift        recording pill: non-activating NSPanel (never steals
                              focus), waveform bars + timer, bottom-right
    ToastPanel.swift          transient acknowledgment toasts, top-right under menu bar
                              (position rationale: same neighborhood as the menu action
                              and later notifications)
    HelpWindow.swift          "Help…" menu item: non-modal window describing the hotkey,
                              every menu item, indicators, and required permissions —
                              keep it in sync when menu items change
  susurro-cli/              transcription harness: susurro-cli <model> <wav...>
                              (fixture corpus regression + engine testing)
Tests/SusurroTests/         golden tests (pinned to the Python predecessor's output),
                            filter tests, rules-config tests
Fixtures/                   voice test clips (corpus; add a clip whenever a real-world
                            mishear is worth pinning)
Support/                    Info.plist, entitlements, AppIcon.icns
vendor/whisper.cpp          submodule, pinned v1.9.1
```

## One dictation, end to end

```
key down (CGEventTap callback, main runloop)
  → AppDelegate.pttPressed [MainActor]
      AudioRecorder.start()          AVAudioEngine tap begins accumulating samples
      OverlayController.show()       non-activating panel; focus untouched
      levels → overlay waveform      audio thread → DispatchQueue.main hop
key up
  → AppDelegate.pttReleased [MainActor]
      samples = recorder.stop()
      overlay.hide()
      Task.detached:                 off the main thread
        WhisperEngine.transcribe()   0.2–0.7s typical (small.en, warm, Metal)
        TranscriptFilter             drop [BLANK_AUDIO]-style hallucinations
        PostProcessor.process()      rules.json: punctuation words, substitutions, regex
        [TranscriptCleaner.clean()]  only if AI Cleanup toggled on; ~1s+; falls back
        → MainActor:
            [DictationMemory]        only if Smart Spacing is on and no secure field is
                                     focused: SpacingRule checks the tail Susurro itself
                                     last typed into this same frontmost app (pid match),
                                     decides whether to prepend a space
            TextInjector.type(text)  CGEvent posting into focused app
            DictationMemory.record   remembers this text's tail + frontmost pid for the
                                     next dictation (or clears it if nothing was typed)
            [clipboard = text]       only if the "Copy Transcript to Clipboard"
                                     toggle is on (default OFF — user clipboard is
                                     sacred), OR IsSecureEventInputEnabled() is true
                                     (password fields drop synthetic keystrokes; the
                                     copy + a toast keep the words from being lost)
```

## Concurrency model

- All UI/menu/AppKit state: `@MainActor` (AppDelegate, panels, HotkeyMonitor).
- Audio tap & CoreAudio callbacks arrive on audio threads; recorders are
  `@unchecked Sendable` with `NSLock`-guarded sample buffers.
- Transcription runs in `Task.detached`; `WhisperEngine.transcribe` holds an
  internal lock because whisper_context is not reentrant.
- Event-tap C callback runs on the main runloop → `MainActor.assumeIsolated`.
- Strict concurrency is ON (Swift 6). Compile errors around Sendable are the
  norm when touching this code; the patterns above are the house answers.

## Persistence & user data

| What | Where |
|---|---|
| Models | `~/Library/Application Support/Susurro/models/*.bin` |
| Rules | `~/Library/Application Support/Susurro/rules.json` (created from DefaultRules on first run) |
| Active model | UserDefaults `activeModelID` (default "small.en") |
| PTT key | UserDefaults `pttKeyID` (default rightOption) |
| AI cleanup | UserDefaults `llmCleanupEnabled` (default false) |
| Clipboard copy | UserDefaults `copyToClipboard` (default false; secure-input auto-copy is unconditional) |
| Smart Spacing | UserDefaults `smartSpacingEnabled` (default false) |
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
  permission + start latency. Full experiment log in PLAN.md.
- **whisper small.en beat Apple's SpeechTranscriber** on technical vocabulary
  and verbal-punctuation handling in the original spike (see ptt repo
  spike/ and PLAN.md); engine is behind a de-facto interface if that changes.
- **whisper.cpp is linked statically** (`make whisper` → `build-whisper/`,
  flags in Package.swift `whisperLinkerSettings`), Metal embedded
  (`GGML_METAL_EMBED_LIBRARY=ON`), OpenMP disabled (Homebrew libomp leak).
- **Whisper hallucinates on silence** ("[BLANK_AUDIO]") — TranscriptFilter
  strips square-bracket tokens; parentheses are preserved deliberately.
- **Reading a focused field's content via Accessibility does not generalize
  across apps.** `kAXSelectedTextRangeAttribute` (cursor position) is only
  reliably implemented by native Cocoa text views. Electron apps and
  Chromium/WebKit web content expose cursor position via a different,
  non-standard mechanism (`AXTextMarkerRange`); Terminal's custom-drawn text
  view doesn't expose per-character selection via AX at all. An
  AX-read-based Smart Spacing design was built, tested, and abandoned for
  this reason (empirically: it worked in TextEdit, silently did nothing in
  Claude desktop/Terminal/browser fields) in favor of `DictationMemory`
  self-tracking what Susurro itself typed. See SMART_SPACING_PLAN.md.
- ~600 MB resident with small.en warm; scales with model choice.

## Debug affordances

- `kill -USR1 <pid>` toggles recording (scripted testing without a human).
- Run `./build/Susurro.app/Contents/MacOS/Susurro` directly from a terminal to
  see stderr logs (via `open`/LaunchServices, NSLog content is TCC-redacted in
  `log show`).
- `susurro-cli <model.bin> Fixtures/*.wav` — corpus regression in seconds.
