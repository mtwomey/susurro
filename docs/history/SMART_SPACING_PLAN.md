# Smart Spacing — feature plan

> Status: **built**, on branch `feature/smart-spacing`, using the
> **self-tracking design** (see below). Companion to `ARCHITECTURE.md`
> (as-built structure) and `PLAN.md` (v1 historical design doc) — where this
> document and reality differ, they win, per this repo's usual convention.
>
> This feature went through two designs. The first (Accessibility-based field
> reading) was built, tested on real hardware, and abandoned when testing
> showed it silently failed almost everywhere except native Cocoa apps. The
> "Pivot" section below explains why, and "Historical: AX-based design (superseded)"
> preserves the abandoned design for the reasoning, per this repo's usual
> practice of keeping rejected-alternative writeups (see `PLAN.md`).
>
> The trigger condition was later broadened past the original "ends in
> `.`/`!`/`?`" spec — see "Revision: broadened trigger condition" below —
> after review turned up that the sentence-ender gate missed the more common
> case (resuming mid-sentence, with no ending punctuation at all).

## Problem

Susurro is stateless across dictations: it has no idea what's already in the
focused text field. Dictate something, release the hotkey, click back into
the same field a moment later and dictate again — the new text is typed with
no separating space, e.g. `...done.Next thought...` instead of
`...done. Next thought...`, or, just as often, `...the lightand go
straight...` after pausing mid-sentence with no ending punctuation at all.

## Behavior

On hotkey release, before typing the new transcript: if Susurro itself typed
something into the same app that's still frontmost, and that text doesn't
already end in whitespace, prepend a single space to the new transcript
before typing it. Resuming a dictation always wants a word-boundary space —
you're never picking up mid-word — so there's no need to condition this on
*what* the previous text ended with, only on whether a space is already
there.

Decisions locked in:

| Question | Decision |
|---|---|
| Trigger condition | Any resumed dictation into the same still-frontmost app, unless the last-typed text already ends in whitespace |
| Trailing whitespace/newlines already typed | Checked directly — if the literal last character is whitespace, skip adding another (avoids doubling a space, or adding one right after a newline) |
| Mechanism | Self-tracking: Susurro remembers the last character of what *it* last typed and which app (pid) it typed into — **not** a read of the field's live contents |
| Memory invalid (different app now frontmost, nothing typed yet this session, secure field last time) | Silently do nothing — behaves exactly like today, never blocks or errors |
| Rollout | Opt-in menu toggle, **default off** — "Smart Spacing", same pattern as "Copy Transcript to Clipboard" |

## Pivot: why this isn't Accessibility-based

The first implementation read the focused field's live content via the
Accessibility API (`AXUIElement`) — see the historical section below for the
full design. It was built, unit-tested, and installed on real hardware, and
manual testing turned up a fundamental problem rather than a bug to patch:

**`kAXSelectedTextRangeAttribute`** — the standard way to ask "where's the
cursor" — is only reliably implemented by native Cocoa text views (TextEdit,
Notes, Mail, Pages). Testing against the actual running app confirmed, with
debug logging added specifically to pin this down:

- **TextEdit**: worked correctly.
- **Claude desktop, other Electron apps, Chromium/WebKit web content**
  (browser fields): the AX call chain reached the focused app and element
  fine, but `kAXSelectedTextRangeAttribute` itself came back unreadable.
  Chromium/Electron expose cursor position through a completely different,
  non-standard mechanism (`AXTextMarker`/`AXTextMarkerRange`, opaque tokens
  rather than a plain `CFRange`), which the AX-based design never handled.
- **Terminal**: same failure — its custom-drawn text view doesn't expose
  per-character selection via AX at all.

Along the way, a real bug was also found and fixed (a too-tight
`AXUIElementSetMessagingTimeout` of 150ms was rejecting legitimate-but-slower
cross-process round trips, misreported as "no focused application"), but
fixing that only got as far as isolating the deeper, structural gap above.
Since dictating twice into a chat box, a terminal, or a browser field is
probably *more* common than doing it in TextEdit, an AX-based design would
have shipped a feature that quietly does nothing in most of the places it
matters — an unacceptable gap, not a tuning problem.

**Resolution:** Susurro already knows what it just typed, because it's the
one that typed it (see `TextInjector`). Instead of reading the target app's
UI at all, `DictationMemory` (`Sources/SusurroCore/DictationMemory.swift`)
records the tail of the last-typed transcript plus the frontmost app's pid
at the time. The next dictation checks whether the same app is still
frontmost and, if so, reuses that remembered tail — no Accessibility read,
no per-app compatibility gap, works everywhere Susurro can type.

Trade-offs accepted with this design:
- Doesn't notice if the user manually edited the field (typed, deleted,
  pasted) between two dictations — the memory only reflects what *Susurro*
  typed, not the field's true live state.
- Doesn't notice switching to a *different window in the same app* — only
  the frontmost app's pid is tracked, not a specific window. Switching to
  Finder and back to the exact same document mid-app won't trip it, but
  switching between two windows of the same app might incorrectly carry the
  memory over.
- Resets on every app switch and on every launch (in-memory only, not
  persisted across quits) — both correct/safe defaults, since "no memory"
  just means no leading space gets added, same as today.

## Design (as built)

**`Sources/SusurroCore/DictationMemory.swift`** — pure state, no AppKit/AX
dependency, fully unit-tested:

```swift
public struct DictationMemory {
    public mutating func recordTyped(_ text: String, intoPID pid: pid_t)
    public mutating func clear()
    public func tailIfStillFocused(pid: pid_t) -> String?
}
```

**`Sources/SusurroCore/SpacingRule.swift`** — pure decision logic, unchanged
in spirit from the original plan (this piece never depended on how the tail
was obtained):

```swift
public enum SpacingRule {
    public static func needsLeadingSpace(beforeCursor tail: String?) -> Bool
}
```

`tail` is the last character Susurro itself typed immediately before where
the cursor *was*. The function returns `true` unless `tail` is `nil`/empty
or its last character is already whitespace — see "Revision: broadened
trigger condition" below for why this isn't conditioned on sentence-ending
punctuation anymore.

**`AppDelegate.swift` wiring** — in `pttReleased`'s `MainActor.run` block,
immediately before `TextInjector.type(text)`:

```swift
let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
if !secureInputActive, smartSpacingEnabled, let frontmostPID,
   SpacingRule.needsLeadingSpace(beforeCursor: dictationMemory.tailIfStillFocused(pid: frontmostPID)) {
    text = " " + text
}
TextInjector.type(text)
if !secureInputActive, let frontmostPID {
    dictationMemory.recordTyped(text, intoPID: frontmostPID)
} else {
    dictationMemory.clear()
}
```

`smartSpacingEnabled` is a `UserDefaults`-backed toggle (default `false`),
same pattern as `copyToClipboard`, with a "Smart Spacing" menu item next to
it and a toast on flip (which also clears `dictationMemory` when turned off).

## Testing

- **Unit tests** (`Tests/SusurroTests`):
  - `SpacingRuleTests.swift` — letters, digits, commas, sentence-ending
    punctuation, and closing quote/paren all trigger a space now; trailing
    space/newline, empty, and nil all correctly don't.
  - `DictationMemoryTests.swift` — recorded tail returned for a matching
    pid, hidden for a different pid, cleared explicitly, single-character
    text handled, re-recording overwrites the previous entry. Fully
    mockable (`pid_t` + `String` only), no AX/AppKit involved.
- **Manual acceptance** (`CHECKLIST.md` — "Smart Spacing" section): app
  switching resets the memory, works identically across TextEdit/Electron/
  Terminal/browser (the whole point of the redesign), manual edits between
  dictations are a documented non-goal rather than a bug, secure fields
  clear rather than record.

## Out of scope / risks

- No attempt to detect a text *selection* ("replace this") — self-tracking
  has no visibility into selections at all; if the user selects text and
  dictates over it, Smart Spacing has no opinion (it only ever prepends to
  what's being typed).
- Window-level granularity within the same app isn't tracked (see Pivot
  trade-offs above) — a known, accepted limitation, not a bug.
- Not scoped to fix multi-space accumulation from *pre-existing* trailing
  whitespace the user typed manually — the whitespace-trim only affects this
  feature's own decision, it does not rewrite the field's existing content.

## Revision: broadened trigger condition

The original spec (see "Problem" and the first `Behavior` decision table
above, as originally written) only added a space when the previous typed
text ended in `.`, `!`, or `?` (optionally behind a closing quote/paren).
That was scoped directly from the motivating example — finishing a
sentence, then dictating the next one — and never considered the more
common case: pausing *mid-sentence*, with no ending punctuation, and
resuming a moment later. Under the original rule that case got no help at
all (`the light` + `and go straight` → `the lightand go straight`, glued
together, feature on or off), which is arguably a bigger real-world gap than
the one this feature originally set out to fix — a push-to-talk user is
essentially never picking up in the middle of a word, so *any* resumed
dictation wants a word-boundary space, not just one after a finished
sentence.

Revised rule: add a leading space whenever resuming into the same
still-frontmost app, unless the last-typed text already ends in whitespace.
This drops the sentence-ender/closing-wrapper check in `SpacingRule`
entirely — checking only whether the last character is whitespace covers
both "don't double an existing space" and "don't add a stray leading space
right after a newline."

One risk considered and ruled out: whether this could cause double spaces
if previously-typed text already ended in whitespace. It can't, in
practice — `PostProcessor.process()` already runs
`.trimmingCharacters(in: .whitespacesAndNewlines)` on the full transcript by
default (`normalizeWhitespace: true` in `rules.json`), so what actually gets
typed essentially never ends in trailing whitespace already. The
whitespace check in `SpacingRule` is kept anyway as a defensive guard for
anyone who disables `normalizeWhitespace` in a custom `rules.json`.

`DictationMemory`'s `contextLength` was reduced from 8 to 1 accordingly —
`SpacingRule` only ever looks at the single character immediately before the
cursor now, so there's no reason to retain more.

---

## Historical: AX-based design (superseded)

Preserved for the reasoning and the independent-review process it went
through, per this repo's convention of keeping rejected-alternative writeups
(see `PLAN.md`). **Do not resurrect this without a concrete plan for
Chromium's `AXTextMarker` API and Terminal's lack of AX text-position
support** — both gaps were structural, not bugs.

### Original behavior spec

Read the focused field's existing text via the macOS Accessibility API
(`AXUIElement`) and decide whether to prepend a space, instead of
self-tracking what Susurro had typed.

### Why it needed new capability

Susurro had never read a text field's contents — `TextInjector` only
*writes* via CGEvents. Reading the focused field's existing text and cursor
position required `AXUIElement`, riding on the Accessibility permission
Susurro already requires for the hotkey (no new permission prompt — macOS
has one Accessibility checkbox covering both posting synthetic events and
querying other apps' UI, not a separate "read" grant).

### Design (as it was built and then removed)

**`Sources/Susurro/FocusedFieldInspector.swift`** (deleted):
1. `AXUIElementSetMessagingTimeout` on every AX call (~100–150ms originally;
   found during testing to be too tight — see Pivot above) so a busy/hung
   frontmost app can't stall Susurro's own main runloop, the same one
   `HotkeyMonitor`'s CGEventTap lives on.
2. `AXUIElementCreateSystemWide()` → `kAXFocusedApplicationAttribute` →
   `kAXFocusedUIElementAttribute` on that element (two-step lookup, more
   reliable across apps than system-wide → focused element directly).
3. `kAXSelectedTextRangeAttribute` for cursor position (`AXValue` wrapping a
   `CFRange`; `AXValueGetType(_:) == .cfRange` checked before unwrapping). An
   empty-length range = plain cursor; non-empty = a selection, treated as
   unreadable/no-op.
4. A small bounded slice (last 8 characters before the cursor) via
   `kAXStringForRangeParameterizedAttribute` — deliberately never the whole
   field value, both for cost and to avoid holding more of a field's content
   than necessary.
5. On any failure, an `slog` line before returning nil — which is exactly
   what made the Electron/Terminal/browser failures diagnosable rather than
   just "mysteriously doesn't work."

### Independent review (before the pivot)

An independent reviewer went over this design before implementation and
flagged two **blocking** issues, both fixed in the build above before the
pivot was even discovered:
1. **No AX call timeout** — fixed via `AXUIElementSetMessagingTimeout`
   (though the chosen value turned out to still be part of the eventual
   real-world bug — see Pivot).
2. **Full-value read instead of bounded range** — fixed by always
   requesting a small bounded slice directly rather than the whole field.

Should-fix items also addressed: explicit `AXValue`/`CFRange` unwrapping;
`kAXFocusedApplicationAttribute` → `kAXFocusedUIElementAttribute` two-step
lookup; a diagnostic `slog` line on failure (this is precisely what
localized the Electron/Terminal/browser gap during real-hardware testing);
IME composition and Chrome/Safari `AXWebArea` contenteditable added to the
manual checklist.

Not folded in (tracked, not Susurro-specific): CJK/ideographic
sentence-ending punctuation (`。` `！` `？`) — moot now, and was already low
priority since the whisper engine in use (`small.en`) is English-only.
