# Text-handling layer: findings (BEA-647)

Fact-finding only; nothing here is implemented. Branch `feature/parakeet-v2` at `35d8bb5`.

## 1. What exists today

There is no text-handling layer as such. Between "we have a transcript" and "keystrokes are posted",
the work is split across four places, and only the last one knows anything about the target field:

| Step | Where | Knows the field? |
|---|---|---|
| `engine.transcribe` | `Sources/Susurro/AppDelegate.swift:688` | no |
| `TranscriptFilter.stripHallucinations` | `AppDelegate.swift:696` | no |
| `PostProcessor.process` (rules.json; step 6 trims, step 7 capitalises the first letter) | `AppDelegate.swift:697`, `Sources/SusurroCore/PostProcessor.swift:155-177` | no |
| optional `TranscriptCleaner` (AI Cleanup) | `AppDelegate.swift:698-700` | no |
| Smart Spacing: `SpacingRule.needsLeadingSpace(beforeCursor: dictationMemory.tailIfStillFocused(pid:))` | `AppDelegate.swift:711-716` | self-tracked memory only |
| `TextInjector.type` (CGEvent unicode strings) | `AppDelegate.swift:717`, `Sources/Susurro/TextInjector.swift:17` | no |
| `dictationMemory.recordTyped` / `clear` | `AppDelegate.swift:718-726` | — |

`DictationMemory` (`Sources/SusurroCore/DictationMemory.swift:20-47`) stores exactly one character
(`contextLength = 1`, line 23) plus the frontmost **pid** it was typed into. `tailIfStillFocused` (line 44)
returns that character whenever the frontmost pid matches. There is no notion of window, field, time or
user keystrokes. `SpacingRule.needsLeadingSpace` (`SpacingRule.swift:17-20`) returns true whenever that
remembered character is not whitespace.

Capitalisation is decided before the field context is even consulted: PostProcessor and AI Cleanup run in
the detached transcription task (`AppDelegate.swift:685-700`), and the spacing context is only looked up
afterwards on the main actor (`:702-716`). Nothing passes context into the capitalisation step.

## 2. The three symptoms

Repro: `DictationMemory.swift`, `SpacingRule.swift`, `PostProcessor.swift` and `DefaultRules.swift`
compiled with a small driver (`swiftc`, real user rules.json), simulating the same calls AppDelegate makes.
Output, verbatim:

```
S1 first in Slack: "Hello there."
S1 after Enter-sent, empty field, same pid: " Next message."
S2 user typed a space manually, then dictates: " we should go" -> field 'I think ' + that = double space
S3 continuation after 'I think' (no end punct): "We should go"
```

### 2.1 Leading space in an empty field — reproduced (logic level)
Mechanism: the memory is keyed on pid only (`DictationMemory.swift:44-46`). Anything that empties or
changes the field without changing the frontmost app leaves the old tail in place, and
`needsLeadingSpace` then prepends a space (`AppDelegate.swift:711-716`). Common triggers:
- pressing Return to send in Slack/Messages/Claude/ChatGPT (the field is cleared, same pid) — the most
  likely everyday cause;
- clicking into a different field, tab or window of the same app (browser search box, new email,
  another Slack channel);
- selecting all and deleting, or Cmd-Z undoing the dictation.
Only an app switch, a failed/secure-field type, or toggling Smart Spacing clears the memory
(`AppDelegate.swift:589`, `:725`). The doc comment at `DictationMemory.swift:16-19` already names this gap.

### 2.2 Double spaces — reproduced (logic level)
Mechanism: Susurro never sees the user's own keystrokes. After a dictation ending in "k", the user types a
space by hand; the memory still says "k", so the next dictation gets `" "` prepended → two spaces.
The same happens if the user types any text ending in a space, or if the cursor was moved next to an
existing space. A second, weaker path: PostProcessor step 6 trims (`PostProcessor.swift:159`), but only
when `normalizeWhitespace` is on; AI Cleanup output is not re-trimmed before the space is added (not seen
in testing, noted as a possibility).

### 2.3 Capital letter on a continuation — reproduced
Mechanism, two layers:
1. `PostProcessor.swift:175-177` upper-cases the first letter of every transcript unconditionally; it has
   no input about what precedes the cursor.
2. The engines themselves (Whisper and Parakeet) emit sentence-cased output, so "we should go" usually
   arrives as "We should go" already. Turning off `autoCapitalize` therefore would not fix it; the fix must
   actively **lower-case** the first word when the preceding text has no sentence-ending punctuation
   (keeping "I", "I'm", proper nouns/acronyms with internal capitals — the same exemption list
   `lowercaseAfterMidSentenceTrigger` already uses, `PostProcessor.swift:182-188`).
AI Cleanup (`TranscriptCleaner`) is told to fix capitalisation, so it re-capitalises too.
The self-tracked memory holds one character, which is enough to see "no ending punctuation", but it is
consulted only for spacing and only after capitalisation is final.

Not reproduced on device in this ticket (no live dictation run); the logic repro uses the shipped code
paths with the real rules file.

## 3. Options for a pluggable pre-insert stage

### 3.1 Shape (common to all options)
An ordered list of steps run on the main actor just before `TextInjector.type`:

```swift
struct InsertContext {           // built once per dictation
    let before: String?          // text before the cursor (AX if readable, else memory), nil = unknown
    let after: String?           // text after the cursor (AX only)
    let source: Source           // .accessibility / .selfTracked / .none
    let pid: pid_t; let bundleID: String?
    let engine: EngineKind; let secureInput: Bool
}
protocol TextTransform { func apply(_ text: String, _ ctx: InsertContext) -> String }
```
Initial steps: `LeadingSpace` (replaces SpacingRule; no space at field start or after whitespace/open
bracket/quote), `ContinuationCase` (lower-case the first word when `before` ends without `.?!` / newline),
`SentenceCase` (current step 7, moved here so it can see context), `TrailingSpace` policy (optional), and
later per-app rules (e.g. Terminal: never add a space, never capitalise). Each step is a pure function,
so it is unit-testable exactly like `SpacingRule` today. PostProcessor keeps the context-free work
(spoken punctuation, substitutions, regex, numbers); AI Cleanup stays before the stage, and the stage
re-applies the context-dependent case/spacing after it, so Cleanup cannot undo it.
Policy when `before == nil`: do what an empty field needs (no leading space, sentence case) — the opposite
of today, where the unknown case falls through to "assume continuation" whenever the pid matches.

### 3.2 Where the context comes from
**A. Self-tracked only (today, improved).** Keep more than one character, add focus invalidation:
observe the focused AX element / window via `AXObserver` (`kAXFocusedUIElementChangedNotification`) and
clear on change; listen to user keystrokes with a listen-only CGEvent tap (Return, space, Delete,
Cmd-Z/A/V → clear or update memory). Fixes 2.1 for Enter-to-send and field switches, 2.2 for a typed
space. Cost: a keystroke tap needs Input Monitoring (a second permission prompt) or the existing
Accessibility trust for an AX observer; it still guesses after mouse clicks inside the same field.

**B. AX read of the focused field, self-tracked fallback (recommended).** On key-up of push-to-talk,
read `kAXFocusedUIElement` → `kAXValueAttribute` + `kAXSelectedTextRangeAttribute`, or for Chromium/WebKit
`AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange`. Fall back to A when unreadable.
What changed since `SMART_SPACING_PLAN.md` abandoned this: (1) Matthew now allows reading the whole field,
so `kAXValueAttribute` (whole value) is usable instead of the narrow string-for-range call; an empty
value alone solves 2.1 even where the cursor position is unreadable; (2) the earlier design had no
fallback and treated "unreadable" as "do nothing", which is why it "silently did nothing" — with a
fallback it can only improve on today; (3) the read can be done while the engine is transcribing
(hundreds of ms), so latency is off the critical path — the earlier 150 ms timeout was on the critical path.
Expected coverage (from the earlier hardware test and Apple/Chromium AX behaviour; to be re-measured):

| App | value | cursor | Notes |
|---|---|---|---|
| Native NSTextView/NSTextField (TextEdit, Notes, Mail, Messages) | yes | yes (CFRange) | reliable |
| Safari / WebKit fields | yes | text markers | needs marker API |
| Chrome, Electron (Slack, VS Code, Claude, ChatGPT) | yes once `AXEnhancedUserInterface`/`AXManualAccessibility` is set on the app | text markers | Electron exposes nothing until `AXManualAccessibility=true` is set; setting it can slow large Electron apps — measure |
| VS Code editor | partial (Monaco exposes a hidden textarea with a window of lines) | partial | fallback likely |
| Terminal / iTerm | whole buffer, no cursor | no | per-app rule: never add space/capitals via AX; use fallback |
| Secure fields | never read | — | `IsSecureEventInputEnabled()` or role `AXSecureTextField` → skip AX entirely, as today |

Permissions: no new prompt — the app already holds Accessibility for CGEvent posting, and AX reads ride
on the same grant. Privacy: field text stays in memory for one dictation, never logged (the slog of the
transcript at `AppDelegate.swift:701` must not be extended to include context).
Latency: AX calls are IPC to the target app, typically 1–20 ms, with stalls up to the messaging timeout
on a busy app; run them concurrently with transcription and cap at ~250 ms.

**C. Clipboard/selection tricks** (select-to-start, copy) — rejected: destroys the selection and the
clipboard and is visible to the user.

### 3.3 Coexistence
PostProcessor: unchanged except step 7 moves to the stage (or becomes the stage's `SentenceCase` with a
rules.json switch kept for compatibility). AI Cleanup: unchanged; optionally pass `before` to the prompt
later. Smart Spacing menu toggle: becomes the stage's master toggle. Tests: pure transforms over
`InsertContext` fixtures for every symptom above.

## 4. Board decisions (BEA-647 interview, 2026-11-04)
1. Context source: **AX read of the focused field, with self-tracked memory as the fallback** — option B
   in section 3.2 above. (The question form had the same option listed first, as its "A".)
2. Unknown context: **assume an empty field**: no leading space, capitalise the first letter.
3. Priority: **all three cases together** (stray leading space, double space, continuation capital).
4. Branch/release, in the board's words: "It should be its own feature branch and we can merge it after
   the parakeet merge which or we can base it off the parakeet branch. However, we're going to ship these
   together as a new release. In fact, there'll be a third feature we're going to add before we actually
   ship." So the work happens on its own branch, based on `feature/parakeet-v2`, and ships in the same
   release as Parakeet and a third, still-unnamed feature. Text handling is not released on its own.

## 5. Implementation (BEA-648, branch `feature/text-handling`)
- `Sources/SusurroCore/TextHandling.swift`: `InsertContext` (before/after/source/pid/bundleID/engine/
  secureInput), `FieldRead`, `InsertContext.resolve` (AX wins, then self-tracked memory, else unknown;
  secure input or a secure field yields no context), `TextTransform`, and the ordered
  `TextHandlingStage.standard`: `ContinuationCase` → `SentenceCase` → `LeadingSpace`.
  Unknown context = empty field (no space, sentence case). `SpacingRule` is kept but no longer called.
- `PostProcessor.process(_:applySentenceCase:)`: the app passes `false`, so step 7 runs in the stage
  instead; rules.json `options.autoCapitalize` still switches `SentenceCase` on/off. The CLI and goldens
  keep the default (`true`).
- `DictationMemory` keeps a 16-character tail and appends within the same app.
- `Sources/Susurro/FocusedFieldReader.swift`: on push-to-talk release, reads the frontmost app's focused
  element concurrently with transcription, capped at 250 ms (0.2 s AX messaging timeout per call).
  Order: secure role/subrole → skip; `kAXValueAttribute` + `kAXSelectedTextRangeAttribute`; empty value →
  empty field; else text markers (`AXSelectedTextMarkerRange` → `AXStringForTextMarkerRange` from
  `AXStartTextMarker`, accepted only if it is a prefix of the value); sets `AXManualAccessibility`
  once per pid for Electron. The read is discarded if the frontmost app changed before insertion.
- Smart Spacing (menu) is the stage's master toggle: off = no AX read, sentence case only.
- Log line per dictation: `ptt: context source=<accessibility|selfTracked|none> app=<bundle id> known=<bool>`.
  No field text is logged.
- Unit fixtures: `Tests/SusurroTests/TextHandlingTests.swift` (all three symptoms, openers/quotes,
  pronoun I and internal capitals, fallback, secure fields, toggles).

## 6. Device test script (board)
Dogfood build installed with `make install` (`/Applications/Susurro.app`). Smart Spacing on.
In each app — TextEdit, Safari (any text box, e.g. a search field), Chrome (same), Slack (message box),
VS Code (editor), Terminal (prompt) — do these four steps and note what appears:
1. Empty field: dictate "hello there". Expect `Hello there` with no leading space.
2. Without typing, dictate "and then we left". Expect ` and then we left` (one space, lower-case "and").
3. Type a space yourself, then dictate "it was late". Expect exactly one space, lower-case "it".
4. Type a full stop, then dictate "next sentence". Expect ` Next sentence`.
Then clear the field (or send the Slack message with Return) and repeat step 1: no leading space.
Per-app coverage comes from `~/Library/Logs/Susurro/text-handling.log`: one line per dictation
with the app, the context source and the AX read path (lengths/positions only, never text).
The unified log does not keep Susurro's NSLog lines, so `log show` cannot be used for this.
Note: the engines end sentences with a full stop, so step 1 gives `Hello there.`

### 6.1 Per-app coverage (to be filled from the device run)
| App | source seen | steps 1-4 OK | Notes |
|---|---|---|---|
| TextEdit | | | |
| Safari | | | |
| Chrome | | | |
| Slack | | | |
| VS Code | | | |
| Terminal | | | |
| Zen (Gecko) | AX (step 2 lower-cased after the user deleted a full stop, which memory cannot see) | 1, 2, 4 OK; 3 double space | Board run 2026-11-04. Likely cause: Gecko's value omits the typed trailing space while the caret sits past it; handled in 72de228 (caret past value end = trailing space), retest pending |
| Warp | self-tracked fallback (probe: AXTextArea, whole buffer, no caret) | 1, 4 OK; 2 capital "And" after a deleted full stop; 3 double space | Fallback cannot see user edits; board decision pending (accept / buffer-end heuristic / plain per-app rule) |
