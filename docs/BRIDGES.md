# App bridges: target architecture (BEA-691)

Status: **proposed, for board approval before implementation.** It replaces
the ad-hoc layout on `feature/latch-v1` (one `AppBridges.swift`, a closed
`LatchMethod` enum, and a `switch` in `LatchTargets.pin`). Behaviour does not
change. Only the structure, plus two performance improvements, called out
below.

## 1. What a bridge is

A bridge is the per-app code that lets Susurro talk to one app through that
app's own channel. Today there are three: the Emacs server socket, the
Obsidian CLI, and Accessibility for TextEdit. A bridge can offer one or both
capabilities:

| Capability | Used by | Hot path? | Contract |
|---|---|---|---|
| **Context read**: text before the cursor | every dictation into that app (spacing, joins) | yes, inside the 250 ms read cap | blocking, off main; nil = "can't answer quickly", and the generic AX path then applies |
| **Latch**: pin a document position, then per chunk read context, insert, read back, release | latch sessions only | per chunk, off main, inside the ordered insertion queue | blocking, off main; replies `value / gone / unavailable` |

Apps without a bridge pay one dictionary lookup and nothing else: no
sockets, no processes, no observers.

## 2. Forces and the rules they lead to

1. **Keep the project's module rule** (2026-11 architecture review, R2/R3).
   `SusurroCore` holds pure, tested logic plus the *protocols* (seams);
   the `Susurro` app holds the *OS adapters* (AppKit, AX, sockets,
   processes). This is how `Inserter`/`Clipboard`/`FrontmostAppProvider`
   (Core) and `SystemSeams.swift` (app) already work. Bridges follow the same
   rule. That is why each bridge has two halves in two modules (§4). My
   previous comment proposed moving all bridge I/O into Core. That would
   break this rule, and I withdraw it.
2. **Keep policy separate from mechanism.** Whether latch may engage in an
   app is *policy*: the allowlist, later a remote list and self-test
   results. How to talk to the app is *mechanism*: the bridge. A bridge can
   exist without being enabled. TextEdit is the current example.
3. **Open for extension.** Adding a bridge must not mean editing a central
   `enum` + `switch`. Bridges are identified by a string `id`, and the
   allowlist names that id.
4. **Hostile input never becomes code.** Dictated text is only ever
   base64 (Lisp) or a JSON string literal (JS). The builders and parsers are
   pure and unit-tested, which is a second reason the codec half lives in
   Core.
5. **Per-latch state lives in a session object**, not in stateless calls
   that take a pin. Each `LatchTarget` owns its handle (marker, leaf id, AX
   element) and its transport, and releases them. This is better than the
   ticket's suggested `insert(_:at: pin)` form: lifecycle and cleanup sit in
   one place, and persistent connections become possible.
6. **Don't over-engineer.** No dynamic plugin loading, no actors around
   blocking I/O, no async wrappers over synchronous sockets. The review
   already ruled out a plugin system.

## 3. Contracts (SusurroCore)

```swift
// Bridges/BridgeContracts.swift
public protocol AppBridge: Sendable {
    static var id: String { get }            // "emacs", "obsidian", "ax-selected-text"
    var bundleIDs: Set<String> { get }       // apps it can talk to
}
public protocol ContextReadingBridge: AppBridge {
    func textBeforeCursor() -> String?       // blocking, off main, fast or nil
}
public protocol LatchingBridge: AppBridge {
    /// App frontmost. Pins the caret target or explains why not.
    func pin(_ request: LatchPinRequest) -> LatchPinResult
}
public struct LatchPinRequest: Sendable { pid; bundleID; appName }
public enum LatchPinResult { case pinned(any LatchTarget), refused(pill: String) }
public protocol LatchTarget: AnyObject, Sendable {   // unchanged
    var pin: LatchPin { get }
    func context() -> LatchBridgeReply
    func insert(_ text: String) -> LatchBridgeReply
    func release()
}

// Bridges/LatchPolicy.swift: policy only, Codable for a later remote layer
public struct LatchCapability: Codable { bundleID; bridgeID: String; minVersion: String? }
public struct LatchAllowlist { static let bundled; func bridgeID(for bundleID:) -> String? }

// Latch/LatchDelivery.swift: unchanged, bridge-agnostic (verify, failure → clipboard + pill + hands-free)
```

These are capability protocols, not one protocol with dummy defaults. Emacs
conforms to both. Obsidian is latch-only. Its context read for ordinary
dictation stays on AX, as today, and adding one later is just a conformance.
The AX bridge is latch-only.

## 4. Layout

Each bridge has one **codec** file (Core: pure builders and parsers, unit
tested) and one **adapter** file (app: the I/O). The two folders mirror each
other. Shared transports are written once.

```
Sources/SusurroCore/Bridges/
  BridgeContracts.swift        protocols above
  LatchPolicy.swift            allowlist (bundled; remote later)
  Emacs/EmacsCodec.swift       emacsclient quoting, Lisp builders, reply decode  (was EmacsServerProtocol + EmacsLatchLisp)
  Obsidian/ObsidianCodec.swift JS builders, JSON literal, reply decode, version gate (was ObsidianLatchJS)
Sources/SusurroCore/Latch/
  LatchDelivery.swift          delivery policy + LatchPin/ReadBack/Failure (from Latch.swift)

Sources/Susurro/Bridges/
  BridgeRegistry.swift         the ONE list: [EmacsBridge(), ObsidianBridge(), AXSelectedTextBridge()]
                               byBundleID dictionary built once; contextReader(for:), latchPin(for:)
  Transport/UnixSocketClient.swift   request/response with deadline (from the Emacs code; reusable, e.g. a VS Code extension socket)
  Transport/ProcessRunner.swift      spawn with timeout and bounded output (from ObsidianCLI; reusable, e.g. osascript for Terminal/iTerm)
  Emacs/EmacsBridge.swift      ContextReadingBridge + LatchingBridge; EmacsLatchTarget
  Obsidian/ObsidianBridge.swift LatchingBridge; ObsidianLatchTarget
  AX/AXSelectedTextBridge.swift LatchingBridge (generic AX; serves whatever the allowlist names, none today)
```

**Adding a bridge:**
1. Write a codec (if it speaks a language) and an adapter file.
2. Add one line to `BridgeRegistry`.
3. Add one allowlist entry, only once it passes the full-support checks.

There is no central switch to edit.

**Call sites:** `FocusedFieldReader` uses `BridgeRegistry.contextReader(for:)`.
`AppDelegate.hfRequestLatch` uses `BridgeRegistry.latchPin(for:)`, which
checks the allowlist and then calls the bridge's `pin`. Nothing else in the
app knows bridges exist.

## 5. Performance

- **Lookup:** a dictionary keyed by bundle ID, built once. Bridges are
  stateless values, so there is no per-dictation allocation.
- **Context read concurrent with transcription (new).** Today a latched
  chunk reads the pin's context *after* transcription, which adds one
  bridge round trip to every chunk: about 60–150 ms for Obsidian (process
  spawn), 2–35 ms for Emacs. Start it when the chunk is dispatched, in
  parallel with transcription, exactly as the AX field read already works.
  The insert still re-validates the target and reads back, so a user edit in
  between can't cause a wrong-place insert. At worst the spacing is planned
  from slightly stale context, the same trade-off the AX path makes today.
- **Obsidian transport.** Each call spawns the CLI (measured: `version`
  62 ms, `eval` about 150 ms). The adapter talks only through
  `ProcessRunner`. If the undocumented `~/.obsidian-cli.sock` proves faster
  and stable, a persistent per-latch connection can replace it inside
  `ObsidianBridge` alone. I won't build that before measuring.
- **Never on main:** pin happens once per latch, at the user's tap. Context
  and insert run inside the queue job, off main, as today.

## 6. Ownership fixes (deviations from the ticket)

- The ticket puts latch state, pin and validation in `HandsFreeSession`.
  Today `AppDelegate` holds `hfLatch` and `DictationController` runs the
  latch path. Move the pin and its lifecycle (pin, release on stop, discard,
  push-to-talk, or failure) into a small `LatchSession` owned by the
  hands-free session. AppDelegate then only forwards events and draws the
  overlay.
- The ticket says to extend `AppBridge`. §3 does that through capability
  protocols on one `AppBridge` base, instead of the separate, parallel
  `LatchTarget`-only path built so far.

## 7. Not doing (deliberately)

- Runtime-loaded plugins or a bridge SDK: the review ruled this out, and it
  would add attack surface.
- Async/actor wrappers around blocking sockets and processes: no benefit;
  callers are already off main and serialised by the queue.
- A remote list, self-test or passive learning: out of scope, filed as
  BEA-692 to BEA-694. §3's `LatchCapability` is shaped so they plug in
  without touching bridges.

## 8. Migration (behaviour-identical, tests green at each step)

1. Extract `UnixSocketClient` and `ProcessRunner`; Emacs and Obsidian use them.
2. Add the contracts and `BridgeRegistry`; move each bridge into its own
   adapter file and each codec into its Core file. Delete `AppBridges.swift`,
   `LatchMethod` and the switch.
3. Allowlist moves from method enum to `bridgeID`. Update the tests.
4. Add `LatchSession` and move pin ownership out of AppDelegate.
5. Start the context read concurrently with transcription (the only
   behaviour-visible change: lower latency).
6. Verify: full suite, both live scratch tests (Emacs and Obsidian), CI, and
   a rebuild of the test build for a hands-on check.
