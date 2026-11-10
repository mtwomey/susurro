# App bridges: target architecture (BEA-691)

Status: **approved by the board (BEA-691) and implemented** on
`feature/latch-v1`: steps 1–8 in commits 7cb60ba, 0a7a628, 531690a, 4d62045,
c4c08b4, c43a0ef, bcc66be and the docs commit. Originally:
**final recommendation, for board approval before implementation.**
It reconciles my own review (first draft 731bf3f) with an independent review
by a separate agent that saw only the code and the requirements (2026-11-06,
read-only). Where the two differed, the reason for the choice is given in
§9. Every defect in §1 was re-checked against the code before being listed.

## 1. Defects in the current branch (fix before merge, whatever the layout)

1. **Pinning blocks the whole keyboard.** The mode-key tap is handled
   synchronously inside the CGEvent tap callback on the main thread
   (`HotkeyMonitor.swift:97-103` → `onModeTap` → `hfRequestLatch` →
   `LatchTargets.pin`). An Obsidian pin spawns the CLI twice (version, then
   eval), which holds up all keyboard input on the system for about 200 ms,
   and up to 2 × 3 s on timeout. macOS disables a tap that stalls that long.
   `release()` on Esc, push-to-talk or a mode cycle has the same problem.
2. **A failed latch can lose text.** Chunks already queued keep a reference
   to the released target. Each one fails again, and `hfLatchFailed`
   (`AppDelegate.swift:291`) **replaces** the clipboard each time and shows
   another pill. The first failed chunk's words are lost.
3. **Release races with insert.** `release()` runs on main while a queue job
   may be inserting into the same target off main.
4. **Blocking I/O on Swift's cooperative thread pool.** Socket and process
   waits of up to 3 s run in `Task.detached`. The repo's own CappedRead
   lesson says to use GCD for blocking work. The latch path also has no
   per-call time budget.

## 2. Correction to my earlier rule

The first draft assumed SusurroCore must not do I/O. That was wrong. The
actual rule from the November review is **"no AppKit UI in SusurroCore"**:
Core already records audio (AVAudioEngine) and downloads models
(URLSession). The Emacs socket client and the Obsidian process runner need
only Foundation, so they belong in Core, where tests can reach them.

## 3. Rules

- **Capabilities, not one fat protocol.** `ContextReadingBridge` and
  `LatchingBridge` on a common `AppBridge`. The compiler then shows what
  each bridge supports; nothing silently returns nil.
- **Policy separate from mechanism.** The allowlist (bundle ID → bridge id +
  minimum version) decides *whether*; the bridge decides *how*. Latch engages
  only if the allowlist entry exists, the bridge is compiled in, the version
  passes and the pin succeeds. A future remote list can only narrow (revoke,
  raise the minimum), never enable code that isn't shipped.
- **Bridges stay synchronous; one place makes them async.** A per-latch
  `LatchSession` actor runs every bridge call on its own serial GCD queue.
  That means off the main thread, off the cooperative pool, in strict order
  (release included), and with a time budget on each call.
- **Each latch is a session object** that owns its handle (marker, leaf id,
  AX element) and transport, and releases them once. This is better than
  stateless `insert(_:at: pin)` calls, because lifecycle and cleanup sit in
  one place.
- **Dictated text never becomes code.** Only base64 (Lisp) or a JSON literal
  (JS), built by tested functions in the bridge's codec file.
- **Typed errors** (`BridgeError`: notRunning, notEnabled,
  unsupportedVersion, noTarget, targetGone, timeout, malformedReply) and a
  typed `LatchRefusal`. Core turns these into pill text, so every refusal
  path is unit-tested.

## 4. Contracts (sketch)

```swift
public struct BridgeID: RawRepresentable, Hashable, Codable, Sendable { public let rawValue: String }

public protocol AppBridge: Sendable {
    var id: BridgeID { get }
    var bundleIDs: Set<String> { get }
}
public protocol ContextReadingBridge: AppBridge {
    func textBeforeCursor() -> String?          // blocking, off main, inside the 250 ms cap
}
public protocol LatchingBridge: AppBridge {
    var documentNoun: String { get }            // "buffer" / "note" / "document"
    func pin(token: LatchToken, appName: String) throws(BridgeError) -> any LatchTarget
}
public protocol LatchTarget: AnyObject, Sendable {
    var pin: LatchPin { get }                   // display data only
    func context() throws(BridgeError) -> String
    func insert(_ text: String) throws(BridgeError) -> String   // exact read-back
    func release()
}
public actor LatchSession {                     // executor = private serial DispatchQueue
    static func engage(bundleID:appName:allowlist:registry:) async -> Result<LatchSession, LatchRefusal>
    func context(budget: Duration) -> Result<String, LatchFailure>
    func deliver(_ text: String, budget: Duration) -> LatchDelivery.Outcome
    func release()                              // once; later calls fail fast without touching the app
}
```

## 5. Layout: one folder

```
Sources/SusurroCore/Bridges/
  AppBridge.swift            protocols, BridgeID, BridgeError
  BridgeRegistry.swift       the ONE list of bridges; bundleID → bridge, built once (O(1) lookup)
  LatchPolicy.swift          bundled allowlist (Codable; remote layer later), engage decision, pill texts
  LatchSession.swift         actor on a serial DispatchQueue: order, budgets, single failure, idempotent release
  LatchDelivery.swift        read-back verification (moved from Latch.swift)
  Transports/
    UnixSocketClient.swift   request/response with deadline (Emacs; later a VS Code extension socket)
    ProcessRunner.swift      spawn + timeout + separate stderr (Obsidian CLI; later osascript for Terminal/iTerm)
  Emacs/
    EmacsCodec.swift         emacsclient quoting, read + latch Lisp, reply decode
    EmacsBridge.swift        ContextReadingBridge + LatchingBridge; its LatchTarget
  Obsidian/
    ObsidianCodec.swift      JS snippets, JSON literal, reply decode, version gate
    ObsidianBridge.swift     LatchingBridge; its LatchTarget; app version cached per pid
  AX/
    AXSelectedTextBridge.swift  LatchingBridge (registered, not allowlisted: TextEdit's undo check failed)
```

The app module (`Sources/Susurro`) keeps **no bridge code**. Two call sites
use the registry: `FocusedFieldReader` for the context read, and AppDelegate
for engaging latch. `AppBridges.swift`, `EmacsServerProtocol.swift`,
`ObsidianLatchJS.swift`, the `LatchMethod` enum and the `switch` are deleted.

**Adding a bridge:**
1. Create one folder holding a codec file (if the bridge speaks a language)
   and a bridge file.
2. Add one line to `BridgeRegistry`.
3. Add one allowlist entry, only after it passes the full-support checks.

A shared **conformance checklist** covers pin, exact read-back with
unicode, quotes and newlines, mapping through a concurrent edit, gone after
close, and release. It runs against fakes in CI and against the real apps in
the opt-in live suites. It is also what the future "Test <app>" self-test
(BEA-693) will run.

## 6. Performance

- Apps without a bridge cost one dictionary lookup.
- Engaging latch moves off the event-tap callback. The tap returns at once,
  the overlay shows hands-free while the pin runs, and the latch appears when
  the pin succeeds. If the frontmost app changed in the meantime, the latch
  is refused.
- A latched chunk's context read starts **while the chunk is still
  transcribing**, not after. That hides one round trip per chunk (about
  60–150 ms on Obsidian). The insert still re-validates the target and reads
  back.
- Obsidian: the app version is cached per process, so a pin needs one CLI
  spawn instead of two. The CLI stays the transport. The undocumented socket
  is not reverse-engineered; it would be a drop-in `ProcessRunner`
  replacement only if Obsidian documents it.
- Emacs: one socket connection per call is correct (the server protocol is
  one request per connection; about 2 ms to connect).

## 7. Smaller fixes included

- Pin tokens come from a launch nonce plus a counter, not `time % 100000`.
  On pin, the bridge sweeps up pins left by a previous crash: Emacs markers,
  Obsidian `__susurroLatch` entries and the editor wrapper.
- The pill noun comes from the bridge ("buffer" / "note" / "document").
  TextEdit would otherwise say "note".
- Bundle IDs and the Obsidian minimum version are defined once.
  `@unchecked Sendable` is removed where it isn't needed. Obsidian reply
  parsing no longer reads stderr. The CLI path is resolved, not hard-coded.

## 8. Not doing

- Runtime-loaded plugins, XPC helpers, one SwiftPM target per bridge.
- A generic "AX for any app" latch: it fails "full support or nothing".
- Async wrappers inside each bridge: the session does that once.
- Merging the context read and insert into one smart call that plans
  spacing inside the app.
- A remote list, self-test or passive learning: those are BEA-692 to
  BEA-694 (see the sections below). The types are shaped so they plug in later.

## 9. Where the two reviews differed, and the choice

| Topic | First draft | Independent review | Choice and reason |
|---|---|---|---|
| I/O location | app module | Core | **Core.** The real rule is "no AppKit UI"; Core already does I/O, and tests can then reach the transports (§2). |
| Concurrency | no actor, "callers are off main" | session actor on a serial GCD queue | **Actor.** The draft missed defects 1–4; the actor fixes all four in one place. |
| Pin location | at the tap | async, off the tap | **Async.** Defect 1. |
| Errors | value/gone/unavailable | typed `BridgeError` / `LatchRefusal` | **Typed.** Distinct pills, and every refusal path can be tested. |
| AX bridge module | app | app (needs AX/TCC) | **Core.** ApplicationServices is not AppKit UI, and permission belongs to the process, not the module. One folder. |

## 10. Migration (tests green after every step)

1. Constants and codecs into `Core/Bridges` (exact-string tests).
2. Transports into Core behind protocols, with a fake-socket framing test.
   The live suites use the shipping transports.
3. `BridgeID`, `BridgeError` and the pill noun. Pill wording stays identical.
4. Registry + `LatchPolicy.engage` in Core, with a test for every refusal
   path. Delete the switch and `AppBridges.swift`.
5. `LatchSession`, test-first: one pill and **appended** clipboard text
   after a mid-session failure; release ordered after an in-flight insert;
   no bridge call after the session ends. Then engage asynchronously, off the
   tap callback. This step fixes defects 1–4.
6. Start the context read concurrently with transcription; measure the gain
   with `StageTimings`.
7. Pin tokens and the leftover-pin sweep (live suites).
8. ARCHITECTURE and spike docs updated.

**Verify:** full suite, both live scratch suites (Emacs, Obsidian), CI, a
fresh test build for a hands-on check. **Estimate:** about one working day
of agent runs.

## Remote capability list (BEA-692)

`Bridges/RemoteLatchAllowlist.swift` layers a signed list over
`LatchAllowlist.bundled`. Pure and offline: it verifies, merges and caches;
it never fetches.

- **Format.** Hosted/cached bytes are an `Envelope` JSON
  `{keyID, payload, signature}` (base64). `payload` is the exact JSON of a
  `Document` `{schema: 1, serial, expires (ISO 8601), entries: [{bundleID,
  method, minAppVersion}]}`; `signature` is Ed25519 (CryptoKit
  `Curve25519.Signing`) over those bytes.
- **Merge.** Entries apply in order over the bundled list: `method: null`
  removes the bundle ID (remote kill switch), anything else adds or replaces.
  A remote list cannot widen support past compiled-in code: engage still
  refuses with `bridgeMissing` when the build lacks the bridge.
- **minAppVersion.** `LatchCapability.minAppVersion` (optional, so existing
  entries decode). `LatchPinRequest.appVersion` is filled from the app's
  `CFBundleShortVersionString`; a set minimum with an unknown or lower
  version refuses with `appVersionTooOld` ("Latching needs <app> x.y or
  later") before the bridge is touched. Full support or nothing.
- **Resolution.** `resolve(fetched:cached:serialFloor:now:)`: a verified
  fetch wins (and is returned for caching), else a verified cache, else the
  bundled list. Every failure (malformed, unknown key, bad signature,
  schema, expired, serial below the floor) falls back; it never fails open.
  `serial` is anti-rollback; `expires` bounds offline use of a cached copy.
- **Inert in this build.** `RemoteLatchAllowlist.trustedKeys` is empty and
  nothing fetches, so the bundled allowlist is always in force. Switching it
  on needs: hosting URL, key custody, a fetch (ephemeral `URLSession`, no
  cookies/identifiers, plain GET of one static file), the cache path
  (`~/Library/Application Support/<bundle id>/latch-capabilities.json`) and a
  persisted serial floor — decisions left to the board.

## Guided self-test: "Test <app>" (BEA-693)

`Sources/SusurroCore/Bridges/LatchSelfTest.swift`. The core of the guided
self-test from LATCH_FEASIBILITY.md "Capability detection": the user puts the
caret in a scratch field, Susurro runs the four-criteria probe, removes its
marker and records the result locally.

- **Probe** (`LatchSelfTest.run`): pin the focused field → read value + caret
  (*context*) → move the target to the background → element still valid and
  caret unchanged (*identity*) → deliver a zero-width-wrapped marker
  (`susurro-probe-<nonce>`, nonce from `LatchToken`, never input) and read the
  value back: it must equal the old value with exactly the marker spliced in at
  the caret (*background delivery*; an API success that inserts nothing fails)
  → caret after the marker (*read-back*) → remove the marker and confirm the
  field is back to its original value. Stops at the first failure.
- **Never a blind delete:** if the field changed but not by exactly the marker,
  nothing is removed; the result says `markerLeftBehind` and the pill asks the
  user to delete it.
- **Side effects** go through `LatchProbeDriver` (pin, background, validity,
  context, deliver, remove). Fakes in `LatchSelfTestTests`; the AX /
  `postToPid` drivers belong in the app target.
- **Record** (`LatchSelfTestStore`): `~/Library/Application Support/Susurro/latch-selftests.json`,
  one result per bundle ID, text-free (criteria, pass/fail, reason, app version,
  method, date; never field content or the marker). Version-tied: a pass for
  another version reads `.recheckNeeded`.
- **Advisory in this build.** `LatchSelfTestStore.admitsLatch == false`: a
  local pass does not reach `LatchPolicy.engage`. Full support or nothing, and
  no validating delivery path exists yet for non-bridge apps (the AX bridge
  failed TextEdit's undo check in BEA-691). Wiring a pass into the policy is a
  board decision; when it happens, a remote revocation (BEA-692) must still
  override a local pass.
- **Not wired into the UI yet.** The "Test <app>" pill action and the AX
  driver need focus changes and typing into a real app, which can't be run or
  verified unattended; the copy (`actionTitle`, `instruction`, result `pill`)
  is in core and tested.

## Passive learning (BEA-694)

`Sources/SusurroCore/Bridges/LatchPassiveLearning.swift`. The core of
"passive (no user effort)" qualification from LATCH_FEASIBILITY.md: during
ordinary **frontmost** dictation in an unlisted app, try each chunk as an AX
`kAXSelectedText` write, read the field back, and record the outcome per
(bundle ID, field role, app version) without user action.

- **Attempt gate** (`shouldAttempt`): selected text settable, value + caret
  readable, no secure field, no secure input. Settable is only a filter, not a
  predictor (VS Code and Obsidian report settable and silently no-op).
- **Classifier** (`classify`): from the before/after read-backs only, never an
  API return code. `.all` = old value with exactly the chunk spliced in at the
  caret and the caret after it; `.none` = value and caret unchanged; anything
  else, including an unreadable read-back, is `.partial`.
- **Fallback rule** (`needsTypedFallback`): type the chunk the normal way
  only after a proven `.none`. After `.partial` nothing is typed or deleted
  (typing could double it; the spike saw 0 partials in 23 trials).
- **Ledger** (`LatchPassiveLedger`, `LatchPassiveStore` at
  `~/Library/Application Support/Susurro/latch-passive.json`): text-free
  counts only (successes / no-ops / partials, date). Verdict: any partial →
  `unsafe`; any no-op → `notCapable` (full support or nothing); 5 clean
  inserts (`candidateThreshold`) → `candidate`; otherwise `learning`. Field
  roles are tallied separately (a canvas editor inside a supported app). A new
  app version starts over; a query for another version reads `recheckNeeded`.
- **Candidate is advisory** (`admitsLatch == false`). Frontmost observation
  proves context, read-back and AX insertion, but cannot see identity after
  focus loss or background delivery, so a candidate at most points the user to
  the guided self-test (BEA-693); it never reaches `LatchPolicy.engage`.
- **Off and not wired** (`enabledByDefault == false`). Hooking it into the
  insertion path changes how text reaches every unlisted app; it needs the
  frontmost live run on Slack, Hermes and Zen first (the spike covered only
  TextEdit, VS Code, Obsidian and Warp), and that run takes the user's focus.

## Further bridges: probe verdicts (BEA-695)

The four criteria (LATCH_FEASIBILITY.md): **context** (read text + caret at
the pin), **identity** (the pinned target survives focus loss), **background
delivery** (text lands with the app in the background, exactly), **read-back**
(the result can be verified exactly). Full support or nothing: an app joins
`LatchAllowlist.bundled` only when all four pass on a live run. This pass was
done unattended (Matthew away), so it used only what needs no focus: AppleScript
dictionaries (`sdef`, which does not launch the app), compile checks
(`osacompile`) and the BEA-691 spike results. **No app was added to the
allowlist and no bridge was registered.**

| App | Mechanism | Context | Identity | Delivery | Read-back | Verdict |
|---|---|---|---|---|---|---|
| Terminal.app | AppleScript `do script` | screen only, no caret | tab/tty: yes | **always runs the text as a command** | screen only | **Never.** No non-executing write exists; delivery = command execution. |
| iTerm2 | AppleScript `write text … newline no` to a session by `id` | `contents` = visible screen, no caret | session `id`: yes | yes, keystroke-equivalent into the pty | **no**: screen text is rendered output; readline/zsh editing, autosuggest and full-screen programs (vim, REPLs, Claude Code) transform or consume input | **Not allowlisted.** Fails read-back; delivery into a running program is unverifiable. Safe delivery shape kept in `Bridges/ITerm/ITermCodec.swift` (argv-only text, `newline no`, newline refused, pinned session id), tested, not registered. |
| VS Code | extension + local socket, `TextEditor.edit` on a pinned `TextDocument` + `document.getText()` read-back | yes (in extension) | yes (document URI + tracked offset) | yes | yes | **Feasible, not built.** Needs a VS Code extension shipped and installed into the user's VS Code: a distribution decision (marketplace vs side-load, signing, auto-update), see open decisions. The Swift side reuses `UnixSocketClient` exactly like Emacs. |
| Notes.app | AX (`AXTextArea` in a WebKit-ish view) | unprobed | unprobed | unprobed | unprobed | **Unprobed.** A real probe means creating a scratch note and putting the caret in it (takes focus); queued as a hands-on check. AppleScript `body` is HTML of the whole note, no caret: no latch via scripting. |
| TextEdit | AX `kAXSelectedText` (`AXSelectedTextBridge`) | yes | yes | yes | yes | **Still not allowlisted:** failed the undo check in BEA-691; unchanged. |
| Slack, Warp, Hermes | none known | — | — | — | — | No bridge; only the passive/guided paths (BEA-693/694) could ever qualify them. |

Hands-on checks queued for Matthew (each takes focus):
1. Notes: scratch note, run the BEA-693 four-criteria probe via AX.
2. iTerm (only if he wants terminals at all): confirm the read-back verdict on
   a scratch session at a bare prompt.

### iTerm2 bridge (BEA-700, in progress)

Matthew asked for iTerm2 on BEA-691 (shell prompt, AI agent CLIs, editors, ssh).
`Bridges/ITerm/ITermBridge.swift` + `ITermLatchPolicy.swift`, registered as a
latch bridge (`itermSession`), **not allowlisted** yet.

- Pin: the frontmost window's current session `id` plus its foreground
  `jobName` (iTerm per-session variable).
- Before every chunk (one extra osascript spawn): session alive, `jobName`
  unchanged and allowed; otherwise `.gone` → latch ends, text to clipboard, pill.
- Never Enter: the codec refuses any chunk with a newline/CR.
- Programs (`ITermProgram`): v1 allows shells (zsh/bash/fish/sh/…, login
  "-zsh" form) and agent CLIs by process name (claude, hermes, codex, …).
  Bare `node`/`python` are refused (could be a REPL that evaluates lines).
  Editors (vim/nvim/nano/emacs) and ssh/mosh/tmux/screen are refused with a pill
  — open decisions, see below.
- Read-back (`ITermScreen`): the text before the cursor on the cursor's logical
  line, rebuilt from screen rows (joining soft-wrapped rows via `hard_eol`) and
  the cursor cell (wide chars = 2 cells); the chunk must be its suffix. The
  source is `ITermScreenReading`, meant to be the Python API; with no source the
  pin is refused ("turn on the Python API"), so latch never types blind.

Open decisions: (1) require the Python API for read-back (conservative, current)
vs accept AppleScript `contents` (screen text, no cursor) as a weaker fallback;
(2) editors stay refused unless a mode-safe method is proven; (3) ssh stays
refused (remote program invisible); (4) the real `jobName` of each agent CLI must
be confirmed live (node-hosted agents may report `node`, which is refused).
