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

## Capability detection: full support or nothing (board decision, 2026-11-06)

**Board direction (BEA-678 thread):**
- Latch only targets where *every* latch function works.
- Anywhere else, the second Opt+Cmd tap shows a pill: "Latching isn't supported in <app>". No partial latch, no clipboard-fallback latch.
- A static list is fine, as long as it can be **updated dynamically**, because we can't know which apps users will want.

### What "fully supported" means

A target (app + field kind) is **full** only if all of these held when it was verified:

1. **Background delivery lands** while another app is in front, via a bridge, an AX write or `postToPid`. Proved by reading the field back, never by an API return code: VS Code, Obsidian and Terminal all return `.success` on AX writes that insert nothing.
2. **Context is readable**: the field's value and caret/selection can be read, so smart spacing, continuation and joins (BEA-657/677) work against the background field.
3. **Identity holds**: the remembered element stays valid (not stale) after the app loses focus, and the caret doesn't move.
4. **App state stays consistent**: in web fields the page sees the input, so React/controlled inputs keep it, and undo stays sane.

Anything less is **not supported**. That rules out an "unverified" latch on first use. Trying it live on an unknown app is the "it works but not very well" experience the board wants to avoid.

### Where the list comes from (dynamic, three sources)

1. **Bundled list:** shipped with the app, from probe results.
2. **Remote list:** a `latch-capabilities.json` in the Susurro GitHub repo or release assets. It is fetched at launch and daily (ETag/conditional GET), cached locally, and the bundled copy is used offline. It can **add** apps and **revoke** them (an app update breaks something) without a Susurro release. Entries are keyed by bundle ID + version range + field kind (and, for browsers, the field type: textarea / contenteditable / canvas editor). Each entry records the delivery method and the date it was verified. Only HTTPS from the repo, no telemetry.
3. **Local qualification on the user's machine**, so apps nobody listed can become supported:
   - **Passive (no user effort):** during ordinary frontmost dictation in an unlisted app, Susurro already reads the field (FocusedFieldReader). AX writes don't depend on which app is active, so when the field reports `kAXSelectedText` as settable and read-back is possible, Susurro can insert that chunk with an AX write and verify it by read-back. If it lands, criteria 1, 2 and 4 are met for AX. If it doesn't land, nothing was inserted, so Susurro types the chunk the normal way and the user sees no difference. A few successful chunks qualify the app/field kind for AX-based latch. *Risk: this changes the normal insertion path for unlisted apps. It needs a strict "AX no-op or full insert, never partial" read-back check, or it stays behind a setting. Spike before committing.*
   - **Guided self-test (one click):** the "not supported" pill offers "Test <app>". Susurro asks the user to put the caret in a scratch field, brings its own window forward, then runs the probe: AX write, `postToPid`, read-back, context read. It removes the marker it typed and records the result. This is the only way to qualify `postToPid`-only apps (terminals, Obsidian), because background keystroke acceptance can't be observed while the app is in front.
   - Local entries are tied to the app's version. After an app update they drop to "re-check needed" until a passive check or a self-test passes again. A revocation on the remote list overrides a local pass.

### At latch time (fast, ~2–5 ms, target still in front)

1. Secure field or secure input on: pill "Latching isn't available in password fields".
2. Look up (bundle ID, version, field kind) in local ∪ remote ∪ bundled.
3. Re-check the field itself against the entry: the role matches, the value and selection can be read, and selected text is settable where the method is AX. This catches the unsupported field inside a supported app, such as a canvas editor in Zen.
4. Pass: latch, with the app icon and name on the pill. Fail: the pill "Latching isn't supported in <app>", recording carries on in hands-free (the board can choose "stop" instead).

### While latched

Every chunk is still verified by read-back. If one fails (the app updated, or the field was re-rendered):
- **end latch**, with pill "Latch ended: <app> stopped accepting text". Recording carries on as hands-free, or stops; see the open question.
- put that chunk on the clipboard so nothing is lost.
- demote the local entry.

Latch never keeps going in a degraded state.

### What this means for the apps probed so far (strict criteria)

- **Likely full at launch, after checking criteria 2–4:** native AppKit text (TextEdit, Notes), Zen textareas (the React/contenteditable check is still owed), Emacs (bridge), Terminal (postToPid; context read still to be confirmed), Obsidian (postToPid; the read-back miss seen in the probe needs a re-check).
- **Not supported today:** VS Code, Slack, Hermes desktop (expected; Slack and Hermes not yet tested on throwaway fields), Warp (not tested).

The board's choice gives a shorter list of apps that all work properly. That matches the stated goal.

### Effort impact

- Bundled + remote list, lookup, pill: about 0.5 day.
- Guided self-test: about 1 day (most of it is the spike probe).
- Passive AX qualification: about 1 day plus a spike. It touches the normal insertion path, so it lands last and behind a setting.
- Removing partial/clipboard latch modes **saves** about 0.5 day.
- Net: about +2 days on the earlier estimate, so the latch build is about 5 days after BEA-660 R1–R4.

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

## Board decisions (2026-11-06, BEA-678 interview)

- **Go/no-go:** probe the gaps first (Slack, Hermes desktop, Warp, VS Code with Stage Manager off; React/contenteditable input; Obsidian read-back; strict full-support criteria for each launch app; the passive-learning spike). Go/no-go follows the probe.
- **Apps:** no hard must-have list. Support is whatever passes the full-support criteria, and the dynamic list grows from there.
- **Focus hop:** rejected. Latch is all or nothing.
- **Chord:** while PTT is held, Cmd taps cycle through **three** states: push-to-talk (normal) → hands-free → latch → push-to-talk … Releasing PTT in the push-to-talk state stops and inserts, as today. So a third tap backs out of latch without stopping. On a refused latch tap, the cycle lands on hands-free and shows the pill.
- **Rename** latched → hands-free as part of the latch work.
- **Sequencing:** no wait. BEA-660 R1–R8, BEA-677 and v0.2.0 are all done (origin/main 812c8d1).
- **Passive learning:** wanted, and always on (no setting) **if** the spike shows it is reliable, with no double or partial inserts.
- **Refused or ended latch:** keep recording in hands-free.
