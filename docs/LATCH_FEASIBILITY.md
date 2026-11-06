# Latch mode: feasibility (BEA-678)

Spike only. Nothing here is merged to main. Probe: `spike/latch-probe/probe.swift`.

## Names

- **Hands-free**: today's "latched" recording (BEA-651). Recording continues after PTT is released; text goes to the frontmost app; switching apps stops the session.
- **Latch** (new): like hands-free, but text keeps going to the app and field where dictation started while the user works in other windows.

## What the probe does

For each app, the probe:

1. Activates the app and remembers its focused AX element.
2. Activates Finder, standing in for "the user is working somewhere else".
3. Tries each background method with a marker (`[ax]`, `[pid]`, `[hop]`).
4. Reads the remembered element's `AXValue` back to see whether the marker landed. After each step it also checks that the frontmost app is still Finder.

Host: macOS 26.6.2 with **Stage Manager on**. Run 2026-11-05.

## Results matrix

| App | Focused element | 1. AX `kAXSelectedText` write | 2. `CGEvent.postToPid` | 4. Focus hop | Notes |
|---|---|---|---|---|---|
| TextEdit (native) | AXTextArea, settable | **works** (36 ms first call, then <1 ms) | **works** | works with an 80 ms settle; **without the settle, the last character went to the wrong app** | Native text views take AX writes in the background, as expected. Notes uses the same AppKit text system; not probed separately. |
| Terminal | AXTextArea, not settable | **no** (err 0 but nothing inserted; the attribute is read-only) | **works** (typed at the shell prompt) | works, ~300 ms | AX cannot write to a terminal. Keystrokes to the pid work. |
| Zen (Firefox engine), `<textarea>` | AXTextArea, settable | **works** (1 ms) | **works** | works, ~210 ms | Surprisingly good. Not verified: whether page JS (React or other frameworks) sees an `input` event after an AX write. That is the known risk for web apps. |
| VS Code (Electron/Monaco) | AXTextArea, settable (Monaco's hidden textarea) | **no** | **no** | **inconclusive** | With Stage Manager on, the window would not come forward in the test, so the hop result is not trustworthy. Monaco ignores AX writes to its hidden textarea. |
| Slack (Electron) | AXGroup, not settable | **no** (read-only) | not tested | not tested | Not written to, to avoid typing into a real Slack draft. Composer is a contenteditable exposed as a group. |
| Hermes desktop (Electron) | AXTextArea, settable | not tested | not tested | not tested | The composer held a 17-character user draft, so the probe did not write to it. Settable suggests AX might work, but Electron usually ignores it (see VS Code). |
| Warp | AXTextArea, not settable, value = scrollback | **no** (read-only) | not tested | not tested | Like Terminal. postToPid is the likely path; not yet verified. |
| Emacs | focused element is AXWindow (no text AX) | **no** | not tested | not tested | Not needed: **EmacsServerBridge** already inserts by bundle ID, without focus. It is the natural latch path, but it targets Emacs's *current* buffer, so latch must pin the buffer name too. |
| Obsidian 1.14.5 (Electron/CodeMirror 6) | AXTextArea, settable | **no** (err 0, 1.2 ms, nothing inserted) | **works** (typed into the note while Finder was frontmost) | works, ~307 ms (the probe's read-back missed it, but the marker is in the saved file) | Probed 2026-11-05 at the board's request (BEA-630), in a scratch note that was deleted afterwards. Unlike VS Code, Obsidian accepts pid-targeted keystrokes in the background, so postToPid is its latch path. The markers landed at the caret (start of the note), so latch must not move the caret. |

Gaps: Slack, Hermes, Warp, VS Code and Emacs postToPid/hop writes still need sacrificial fields (a test Slack DM, a scratch Hermes chat, a fresh Warp tab, VS Code with Stage Manager off) before a go decision. That is about 30 minutes of probing in a follow-up.

## Method assessment

1. **AX write** (`kAXSelectedText` on the remembered element). Very cheap (~1 ms per chunk) with no focus change, and robust for native AppKit text and Firefox-engine textareas. It fails silently on read-only roles: the call returns `.success` and nothing happens. **So every AX write must be verified by reading back** value/length or the selected range. Unknowns: undo grouping, and framework state (React-controlled inputs may not see the change).
2. **postToPid**. Works for Terminal, TextEdit and Zen while they are in the background. It lands in whatever has key focus **inside the target app**, not necessarily the remembered element. If the user clicks another tab or window of the same app, text follows that click. The element must be re-validated before each chunk (below). Electron/Monaco ignores it.
3. **App bridges**. Emacs exists already. Terminal/iTerm via AppleScript `write text` / `do script` are easy, clean and robust, but each one is per-app work.
4. **Focus hop**. 150–300 ms per chunk. Visible flicker, and with Stage Manager it reshuffles the stage. **It mis-delivered a character in this probe when the settle was 0**: posted events were still in flight when focus moved back. Any keys the user presses during the hop go into the latched app. **Not recommended**, except as an explicit opt-in.
5. **Hybrid**: the recommendation, below.

## Recommended design

### Delivery policy per chunk (latch only)

```
target := LatchTarget(pid, bundleID, windowNumber/AXWindow, element, elementRole)
1. validate(target) else -> clipboard + toast "Latched field is gone", end latch (keep recording? -> board)
2. if bridge(bundleID) exists           -> bridge insert (Emacs; Terminal/iTerm later)
3. else if element selText settable     -> AX write, then read back; on mismatch -> step 4
4. else if app's focused element == target.element (CFEqual) && app in postToPid allow-list
                                         -> postToPid typing
5. else                                  -> clipboard + toast (never focus-hop by default)
```

Invariant, kept from hands-free: **text never goes to an app or element other than the latched target.** postToPid only runs while the target app's current AX focused element is `CFEqual` to the remembered one. Checking that costs one AX call per chunk.

### Target validation

- Remember: pid, bundle ID, the element's `AXWindow`, the element, its role, and `AXValue` length or a hash near the caret.
- Before each chunk: is the pid alive? Does `AXUIElementCopyAttributeValue(element, kAXRoleAttribute)` succeed (`kAXErrorInvalidUIElement` means the element is stale)? Is the window still in `AXWindows`?
- Web/Electron fields are often re-rendered, giving a new AXUIElement. Treat a stale element as **lost**, then clipboard + toast. Do not try to re-find it heuristically in v1.
- Secure input (`IsSecureEventInputEnabled`, AXSecureTextField): refuse to latch.

### Joins and text handling

The context for a latched target comes from the remembered element, through `FocusedFieldReader`'s readers pointed at that element rather than the frontmost app's focus. BEA-657/677 joins and held marks therefore need `FocusedFieldReader.snapshot(element:)`, a small refactor. For postToPid-only targets (terminals), context reading is already limited, so today's terminal rules apply. Coordinate with BEA-677 after it merges.

### State machine (HandsFreeMachine)

- Rename `latchedHeld` / `latched` to `handsFreeHeld` / `handsFree`, and add `latchHeld` / `latch` (or a `mode: .handsFree | .latch` payload on the existing two states; that keeps the diff smaller).
- `latchDown` while holding PTT: idle→holding→handsFree→latch→handsFree… cycling, as the board proposed. The first tap behaves exactly as today.
- `appSwitched`: stops `handsFree` (today's behaviour). Ignored in `latch`.
- New events: `targetLost` (stop and send to clipboard), `retarget` (later).
- New effect: `.latchedTo(target)` so the overlay can show the target.
- Esc is captured only while hands-free or latched, as today. In latch the user is typing elsewhere, so a **global Esc steal is a problem**: Esc in the user's current app would cancel dictation. Recommendation: in latch, cancel with PTT+Esc, or click the overlay; do not capture bare Esc.

### Chord

Hold rightOption (PTT) and tap Cmd. The latch key setting already exists; Cmd becomes one option, and taps are captured only while PTT is down (the existing machine already does this). Risks: Option+Cmd is a modifier-only chord, so no app shortcut fires from the taps alone. But if the user presses a letter while both are down, the app gets Opt+Cmd+X. Swallow the Cmd keyDown/keyUp in the tap only while PTT is held. Bare Cmd taps are not used by the system (unlike Fn/Globe or double-Cmd in some launchers). Not yet probed in the live tap.

### UI

The overlay pill shows the mode (hands-free vs latch). In latch it also shows the target app's icon and name, plus the field's AX title/placeholder where available ("Slack: #general"). Clicking the pill offers Stop / Discard / Retarget-to-frontmost. A toast appears when a chunk falls back to the clipboard.

## Capability detection at latch time (board question, 2026-11-06)

Question: can Susurro tell, quickly and automatically, whether the app or field being latched supports full latch?

**Short answer:** partly. A few milliseconds of checks when latching can rule a target **out**, or rule it **in** if it is already known. Static checks alone cannot prove that an unknown target works, because the APIs lie:
- VS Code and Obsidian both report `kAXSelectedText` as settable. Both return `.success` and insert nothing.
- Terminal returns `.success` for a read-only attribute.
- No API tells you whether an app accepts `postToPid` keystrokes in the background.
- "Is it Electron?" doesn't decide it either. Obsidian (Electron) accepts `postToPid`; VS Code (Electron) does not. Slack, VS Code, Obsidian and Hermes all bundle `Electron Framework.framework`.

The only reliable proof is a write that is seen to land. Susurro must not make a test write into a real field: it pollutes undo, sends Slack typing indicators, and can fire React handlers.

**Recommended: three tiers, all cheap.**

1. **At the chord (target is still frontmost, ~2–5 ms):**
   - Secure field or `IsSecureEventInputEnabled`: refuse latch.
   - Bridge available (Emacs; later Terminal/iTerm): **full**.
   - Look up `bundleID` (+ major version, + field role) in a capability table. The table is shipped from probe results, and the machine adds what it learns. A hit gives **full** (and which method), **clipboard-only**, or **no**.
   - Context readability, which decides whether joins work in full: can `AXValue` and the selected range be read? `FocusedFieldReader` already does this read.
2. **Unknown target:** latch as **unverified**. Deliver the first chunk with the best candidate method, then **verify by read-back** (value length/hash changed at the caret).
   - Landed: record the method as working for that bundle and role.
   - Did not land: send the chunk to the clipboard with a toast, and record the app as clipboard-only.
   - Read-back impossible (fields that don't expose their value): stay unverified. Keep delivering and say so on the overlay; never claim success.
   - So detection happens on the first real chunk, at no extra cost, and only once per app.
3. **Optional self-test (Settings → "Test latch in…"):** run the spike's probe against a scratch field the user opens. Gives an answer before relying on latch in an app.

**UX that follows:**
- The second Opt+Cmd tap shows a badge on the overlay right away: **Latch ✓** (known full), **Latch ?** (unverified), or **Latch: clipboard** (known not to work).
- If the app is known not to work, the tap could **stay in hands-free** and show "Latch not supported in Slack". The board may prefer that to latching into the clipboard.

**Caveats:**
- The table goes stale when apps update, so key it by major version and let the first-chunk verification override it.
- Context-read success (joins) and delivery success are separate checks; report both.
- Web pages inside a browser vary per site and per field (textarea vs contenteditable vs canvas editors). For browsers, key by role, plus the site domain where available, rather than by bundle alone.

## Performance

AX write plus read-back: ~1–2 ms per chunk after the first call (36 ms cold in TextEdit). Validation adds 2–3 AX calls, each with a 50 ms messaging timeout. postToPid: ~4 ms per character with the current pacing, the same as today's typing. Negligible next to transcription. Focus hop: 150–300 ms per chunk, plus flicker.

## Risks

- Electron apps (Slack, VS Code, probably Hermes) likely accept **none** of the background methods. These are among Matthew's main targets, so latch would mean **clipboard fallback** there, unless a focus hop is allowed. **This is the deciding risk.**
- Silent AX no-ops, so read-back is mandatory.
- postToPid follows the app's internal focus, so equality validation is mandatory.
- Web framework state may diverge after an AX write (unverified).
- Esc semantics in latch (above).

## Effort

- Spike gaps (Slack/Hermes/Warp/VS Code postToPid and hop on sacrificial fields; React input check): 0.5 day.
- Machine rename and latch cycle with tests: 0.5 day.
- LatchTarget, validation and the delivery policy (AX + read-back, postToPid, Emacs bridge, clipboard fallback): 1.5 days.
- `FocusedFieldReader` element-targeted snapshot and join integration (after BEA-677): 1 day.
- Overlay and retarget: 0.5–1 day.
- Total: **about 4–5 days.**

## Recommendation

**Conditional GO** for a v1 that works well in native apps, Firefox-engine browsers and terminals, with Emacs via its bridge. Electron apps (Slack, VS Code, likely Hermes desktop) fall back to the clipboard, with a clear toast, unless the board accepts an opt-in focus hop. Run the 0.5-day gap probe on sacrificial Slack/Hermes fields before committing. If those Electron targets are must-haves and a focus hop is unacceptable, the answer is **no-go**.
