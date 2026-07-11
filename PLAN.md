# Susurro — your amanuensis
## PTT Rewrite Plan — Native macOS App (Swift)

*Draft v2 — 2026-07-11. Decisions from spike + interview.*

**Name:** Susurro (Latin, "I whisper" — a nod to the engine underneath), tagline "your amanuensis." Collision-checked against the macOS dictation space: clear.

## Vision

Replace the Python/sox/osascript/tkinter assembly with a single native menu bar app:
hold a key anywhere, speak, release — the transcript is typed into the focused app.
Built for Matthew first, but clean enough to hand to a coworker.

## Decisions made

| Topic | Decision | Rationale |
|---|---|---|
| Language/UI | Swift, menu bar app (SwiftUI settings, AppKit where needed) | Everything the Python version shells out for has a first-class API |
| Engine | whisper.cpp **in-process** (C API, Metal), small.en default | Spike: beats SpeechTranscriber on technical vocab and verbal punctuation; engine behind a protocol so SpeechTranscriber stays one implementation away |
| NeMo ITN | **Dropped** | Spike: whisper output already ITN-formats numbers/dates/currency; port residual rules only if gaps appear in daily use |
| Punctuation layer | Port the quote/comma/period regexes to Swift | Parity; whisper already handles quote→" natively, layer covers the rest |
| Hotkey | Configurable hold-key (push-to-talk), Right Alt default | Shareability; toggle mode deferred |
| Overlay | Non-activating NSPanel: live waveform + elapsed timer, no text preview | Never steals focus → deletes the entire save/restore-focus dance; text preview possible in v2 without rework |
| LLM cleanup | v1, **opt-in** (settings toggle), Foundation Models on-device | ~0.3–1s extra on short dictations; off the default path |
| History | **Dropped from v1**; transcripts not persisted | Revisit in v2 (menu bar list first, window later) |
| Models | In-app download to Application Support; **size picker in settings** — tiny.en / base.en / small.en (default) / medium.en / large-v3-turbo, showing size + speed/accuracy tradeoff; switching hot-swaps the loaded model | Required for shareability; no more pointing at ~/Git_Repos/whisper.cpp |
| Distribution | Unsigned for now; structure for Developer ID signing later | Signing deferred until sharing is real |
| Repo | Fresh repo: `~/Git_Repos/susurro`; ptt stays as reference until retired | Clean start |

## Architecture

One process. No daemons, no sockets, no pipes, no launchd plists (login item via SMAppService).

```
┌─ MenuBarApp (status item, settings, quit)
│
│  HotkeyMonitor ──▶ RecordingController ──▶ TextInjector
│  (CGEventTap,        │        ▲              (CGEvent keyboard
│   configurable       ▼        │               posting)
│   modifier/key)   AudioRecorder │
│                   (AVAudioEngine,│
│                    16k mono RAM  │
│                    buffer + level│
│                    metering)     │
│                        │         │
│                        ▼         │
│                 TranscriptionEngine (protocol)
│                    └─ WhisperEngine (whisper.cpp C API, Metal,
│                       model loaded once, stays warm)
│                        │
│                        ▼
│                 PostProcessor pipeline
│                    1. Verbal punctuation (Swift Regex port)
│                    2. [opt-in] LLM cleanup (Foundation Models)
│
│  OverlayPanel (NSPanel .nonactivatingPanel — waveform + timer)
│  SettingsWindow (SwiftUI: hotkey recorder, model manager, toggles)
│  ModelManager (download/verify ggml models → Application Support)
└─ PermissionsOnboarding (mic + accessibility, first run)
```

Key deltas vs Python version, beyond consolidation:
- Audio recorded straight into memory — no temp WAV files, no sox
- Model loaded once at launch and kept warm — no whisper-server, no HTTP
- Overlay can't steal focus — `query_frontmost_app` / `switch_to_app` logic deleted entirely
- CGEvent typing — no osascript, no string-escaping bugs, handles newlines properly

## Milestones

**M1 — Core loop (the risky 20%).** Menu bar shell; CGEventTap hold-key (hardcoded Right Alt); AVAudioEngine capture; whisper.cpp linked in-process; CGEvent typing. Exit test: hold, speak, release → correct text in focused app, no daemons running.

**M2 — Overlay.** Non-activating panel, live waveform + timer, positioned bottom-right. Exit test: overlay appears/disappears with key, focus never moves.

**M3 — Post-processing.** Punctuation regex port with unit tests pinned to current Python behavior (golden tests using real utterances). Exit test: clip-3-style dictation matches or beats today's output.

**M4 — Settings & models.** Hotkey recorder UI; model manager: download any of tiny.en / base.en / small.en / medium.en / large-v3-turbo with progress + checksum, switch the active model from settings (hot-swap, no restart), delete unused models; launch-at-login; mic/accessibility onboarding flow. Exit test: fresh Mac (or fresh user account) reaches working dictation without touching a terminal, and switching models takes effect on the next dictation.

**M5 — LLM cleanup (opt-in).** Foundation Models pass behind a settings toggle. Exit test: toggle on → cleaner prose, ≤1s added on 2-sentence dictation; toggle off → identical to M3 behavior.

**M6 — Hardening.** Error states (no mic, model missing, permission revoked), sleep/wake and display-change resilience, memory profile with model resident. Then: run side-by-side with Python ptt for a week → retire it.

## Testing & feedback

**Unit tests (automated, `swift test`).** Post-processing pipeline only — punctuation layer, ITN gap rules, LLM-cleanup prompt handling. Includes golden tests pinned to the current Python `apply_verbal_punctuation` behavior to prove parity.

**Integration tests (automated).** Whisper bridge runs a fixture corpus — audio clips + expected transcripts, seeded from the spike clips — on demand. Any bad transcription encountered in daily use gets its clip + corrected text added to the corpus, making accuracy regressions detectable.

**Manual acceptance checklist (per milestone).** The un-automatable parts: hold/release in various apps (Slack, terminal, browser, full-screen), overlay never steals focus, permissions revocation recovery, sleep/wake. Short written checklist, run at each milestone exit.

**Feedback cadences.**
1. *Per slice:* each build step ends in something demonstrable; Matthew confirms before the next layer goes on.
2. *Per milestone:* exit test (defined above) gates progression.
3. *Dogfooding from end of M1:* Susurro becomes the daily driver while M2–M6 proceed; annoyances become backlog items, bad transcriptions become corpus clips. M6's week-long side-by-side with Python ptt is the retirement gate.

## Risks / open questions

- **Right Alt via CGEventTap** — it's a modifier (flagsChanged, not keyDown); the hotkey recorder must handle both modifier-hold and regular-key-hold. Known pattern, mild fiddliness.
- **Accessibility permission** — event tap + CGEvent posting both need it; app bundle makes this cleaner than bare python3, but the onboarding flow must detect revocation.
- **whisper.cpp linkage** — vendor as git submodule + SPM C target wrapper. Well-trodden (whisper.spm exists as reference), but Metal shader bundling needs care.
- **Foundation Models availability** — requires Apple Intelligence enabled; cleanup feature must degrade gracefully when unavailable.
- **Model download UX** — small.en is ~466 MB; needs progress UI and checksum verification.

## Open investigation: mic-mode pill

**SOLVED (2026-07-11), mechanism identified via ControlCenter log forensics.**
The pill is Control Center's mic-modes module. It engages iff an app holds a true
microphone *input session*: coreaudiod/audiomxd classify it (implicit_category=Record),
ControlCenter receives a `mic:<bundle-id>` attribution, and
`AVControlCenterMicrophoneModuleShouldBeShownForBundleID` returns true → pill.
Ruled out by experiment: signature (ad-hoc vs identity), trigger path, CGEventTap
presence, capture API (AVAudioEngine vs raw HAL IOProc — HALAudioRecorder.swift kept),
launch context, activation policy (accessory vs regular), hardened runtime +
audio-input entitlement. All pill, because all still open a real mic input.
Counter-example explained: AudioRecorder.app captures audio via **ScreenCaptureKit**
(SCStream, mic capture added in macOS 15) — attribution is `aud`/`scr`, not `mic`, so
the mic-modes module never engages. The orange privacy dot appears in all cases.

**SCK alternative — built, measured, rejected (SCKAudioRecorder.swift kept in tree).**
Implementation: SCStream with `captureMicrophone = true` (macOS 15+), minimal 2×2 @ 1fps
display filter (mandatory), `.microphone` stream output → Float32 samples →
AudioResampler.to16kMono. Swap is one line in AppDelegate (`recorder = SCKAudioRecorder()`).
Findings on macOS 26.5:
1. Mic pill: gone — attribution becomes `aud`/`scr`, mic-modes module never engages.
2. BUT a blue screen-recording pill appears instead (AudioRecorder.app has it too —
   user initially mistook it for part of that app's UI). No indicator-free path exists;
   you only choose which badge you wear, and "recording your screen" is a worse label
   than "using the mic" for a dictation tool.
3. Requires Screen Recording TCC (scarier grant than mic).
4. Capture-start dead air measured via SIGUSR1-scripted runs: 162 ms cold,
   75–91 ms warm, vs ~10–20 ms for AVAudioEngine — real risk of clipping the first
   syllable on every dictation. Fails the <50 ms criterion.
Verdict: AVAudioEngine + mic pill is the correct production configuration. Revisit only
if Apple changes indicator policy or adds a first-class low-latency audio-only tap.
Debug hook from this investigation: `kill -USR1 <pid>` toggles recording.

## v2 parking lot

Text preview in overlay (streaming via SpeechTranscriber or chunked whisper) · history (menu bar list → searchable window) · per-app formatting rules · toggle-mode dictation · custom PTT key via validated capture flow (accept modifiers/F-keys, reject typing keys with explanation — replaces the removed F13–F15 menu entries; HotkeyMonitor already supports regular keys) · signing + notarization when sharing becomes real. (Custom vocabulary shipped early as rules.json substitutions.)
