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
  BEA-694. The types are shaped so they plug in later.

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
