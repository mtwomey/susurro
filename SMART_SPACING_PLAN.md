# Smart Spacing — feature plan

> Status: **built**, on branch `feature/smart-spacing`. Companion to
> `ARCHITECTURE.md` (as-built structure) and `PLAN.md` (v1 historical design
> doc) — where this document and reality differ, they win, per this repo's
> usual convention. See "As built" below for what changed during
> implementation.

## As built (deviations from the plan above)

- **`FocusedFieldInspector.swift` lives in `Sources/Susurro`, not
  `Sources/SusurroCore`.** All other AppKit/Accessibility/CoreGraphics
  system-integration code (`TextInjector`, `HotkeyMonitor`) already lives in
  the app target, not the shared core library — `SusurroCore` has no AppKit
  dependency today, and this keeps that boundary intact. `SpacingRule` (the
  pure decision logic) stays in `SusurroCore` as planned and is the piece
  that's actually unit-tested.
- **No `TextBeforeCursorProviding` protocol seam was added.** Matching the
  existing precedent for `TextInjector`/`HotkeyMonitor` (also un-mocked,
  verified only via `CHECKLIST.md`), `FocusedFieldInspector`'s AX plumbing is
  exercised manually rather than through a fake-provider unit test. Only
  `SpacingRule` has automated coverage (`Tests/SusurroTests/SpacingRuleTests.swift`).
- **`SpacingRule.needsLeadingSpace` takes the raw multi-character tail
  string, not a single `Character`.** The "closing quote/paren after a
  sentence-ender" case needs to look at *two* trailing characters (the
  wrapper, then what's behind it), so the API takes
  `beforeCursor tail: String?` and does its own trailing-whitespace trim
  internally, rather than the caller pre-trimming down to one `Character`.
- **The secure-input guard is stricter than "AX read should come back
  masked."** `AppDelegate.pttReleased` checks `IsSecureEventInputEnabled()`
  *before* calling `FocusedFieldInspector` at all, so no AX read is even
  attempted while a secure field is focused — belt-and-suspenders beyond
  relying on the OS to mask the value.

## Problem

Susurro is stateless across dictations: it has no idea what's already in the
focused text field. Dictate a sentence, release the hotkey, click back into
the same field a moment later and dictate again — if the cursor sits right
after a period from the previous dictation, the new text is typed with no
separating space: `...done.Next thought...` instead of
`...done. Next thought...`.

## Behavior

On hotkey release, before typing the new transcript: if the focused field
already has text ending (ignoring trailing whitespace/newlines) in `.`, `!`,
or `?` — optionally followed by a closing quote or paren (`"`, `'`, `)`, `”`,
`’`) — prepend a single space to the transcript before typing it.

Decisions locked in:

| Question | Decision |
|---|---|
| Trigger punctuation | `.` `!` `?` (plus a trailing closing quote/paren after one of those) |
| Trailing whitespace/newlines already in the field | Skipped — check the last *non-whitespace* character, not the literal last character |
| Field unreadable (no AX support, wrong role, empty, permission hiccup) | Silently do nothing — behaves exactly like today, never blocks or errors |
| Rollout | New opt-in menu toggle, **default off** — "Smart Spacing", same pattern as "Copy Transcript to Clipboard" |

## Why this needs new capability

Susurro has never read a text field's contents — `TextInjector` only *writes*
via CGEvents (see `ARCHITECTURE.md`). Reading the focused field's existing
text and cursor position requires the macOS **Accessibility (AX) API**
(`AXUIElement`), which is a new capability for this codebase, though it rides
on the Accessibility permission Susurro already requires for the hotkey — no
new permission prompt.

AX text-reading is not universally reliable: some Electron apps, some
terminal emulators, and custom-drawn text views expose partial or no AX text
attributes. That's why the fallback is unconditionally silent — this feature
must never be able to make dictation worse or throw an error the user sees.

## Design

> Revised after independent review (see "Review findings" below) — the AX
> read must be bounded and timeout-guarded, not a full-value read on an
> unbounded main-thread call.

**New file: `Sources/SusurroCore/FocusedFieldInspector.swift`**

```swift
protocol TextBeforeCursorProviding {
    /// Returns up to `maxLength` characters immediately before the insertion
    /// point in the system's focused text element, or nil if unreadable (no
    /// focused element/app, non-text role, non-empty selection, AX error or
    /// timeout, empty text before cursor, etc). Never throws; failure is nil.
    func textBeforeCursor(maxLength: Int) -> String?
}

enum FocusedFieldInspector: TextBeforeCursorProviding {
    static func textBeforeCursor(maxLength: Int) -> String? { ... }
}
```

The protocol seam exists purely for testability (see Testing, below) — the
real implementation is the only thing that talks to AX.

Implementation sketch:
1. Set `AXUIElementSetMessagingTimeout` (~100–150ms) on the AX calls used
   here. AX round-trips are synchronous cross-process calls that block until
   the target app's main thread responds; without a timeout, a busy or
   hung frontmost app can stall Susurro's own main runloop — the same
   runloop `HotkeyMonitor`'s CGEventTap lives on (see ARCHITECTURE.md's note
   that disabled taps get auto re-enabled, implying this has bitten the app
   before via other stalls). A timeout firing is just another "unreadable"
   case → silent no-op.
2. `AXUIElementCreateSystemWide()` → copy `kAXFocusedApplicationAttribute`
   → then `kAXFocusedUIElementAttribute` on *that* element (the two-step
   path is more reliable across apps than going system-wide → focused
   element directly).
3. Read `kAXSelectedTextRangeAttribute` for the cursor position. This comes
   back as an `AXValue`; check `AXValueGetType(_:) == .cfRange` before
   calling `AXValueGetValue` to unwrap the `CFRange` — this is the first AX
   read anywhere in the codebase, so there's no existing precedent to crash
   into. An empty-length range = plain cursor; a non-empty range is a
   selection ("replace," out of scope) → treat as unreadable/no-op.
4. Never read the full field value. Always request a small bounded slice —
   the last `maxLength` characters (e.g. 8) ending at the cursor offset —
   via `kAXStringForRangeParameterizedAttribute` directly. Reading the whole
   `kAXValueAttribute` first (as an earlier draft of this plan proposed) is
   both slower on large documents/chat histories and means briefly holding
   content that may be sensitive even outside a secure field; a bounded read
   avoids that entirely.
5. Trim trailing whitespace/newlines from the returned slice, return the
   last remaining character (or nil if empty).
6. On any AX failure (nil attribute, wrong type, timeout, thrown-away
   selection), log once via the existing `slog(_:)` helper before returning
   nil — the feature stays silent to the *user*, but a support conversation
   ("Smart Spacing isn't doing anything in App X") needs something to grep
   for in the terminal log.

**`Sources/SusurroCore` pure logic, unit-testable in isolation:**

```swift
enum SpacingRule {
    static func needsLeadingSpace(before char: Character?) -> Bool
}
```

Keeps the "is this a sentence-ending char (optionally through a closing
quote/paren)" logic separate from the AX plumbing, so it can be golden-tested
like `PostProcessor` without a live focused text field.

**`AppDelegate.swift` wiring:**

- New `UserDefaults` key `smartSpacingEnabled` (default `false`), same
  get/set pattern as `copyToClipboard`.
- New menu item "Smart Spacing" beside "Copy Transcript to Clipboard",
  toggled the same way, with a toast on flip.
- In `pttReleased`, immediately before `TextInjector.type(text)`:
  ```swift
  if smartSpacingEnabled,
     let ch = FocusedFieldInspector.lastNonWhitespaceCharBeforeCursor(),
     SpacingRule.needsLeadingSpace(before: ch) {
      text = " " + text
  }
  ```
  This must run on the main thread (AX calls are not guaranteed thread-safe;
  `pttReleased`'s `MainActor.run` block, right before injection, is already
  the right spot).

## Testing

- **Unit tests** (`Tests/SusurroTests`): `SpacingRule.needsLeadingSpace` —
  table-driven over `.`, `!`, `?`, closing quote/paren combinations, letters,
  digits, whitespace, nil. Pure function, no AX dependency, fits the existing
  golden-test style.
- **`FocusedFieldInspector`'s own trim/slice/error-handling logic gets a test
  seam too**, via the `TextBeforeCursorProviding` protocol: a fake provider
  returning canned strings (including nil, empty, and whitespace-only) lets
  the "trim trailing whitespace, take the last char" logic be unit-tested
  without a live AX tree — only the AX plumbing itself (steps 1–4 above)
  stays untestable outside a real app.
- **Manual acceptance** (`CHECKLIST.md` — new section "Smart Spacing"):
  - Toggle on: dictate into a field, click back in after a period, dictate
    again → space appears before the new text.
  - Same, but field ends in `!` / `?` / `."` → space appears.
  - Same, but field ends in a letter/comma → no extra space.
  - Field ends in `. ` (trailing space) or a newline after `.` → no *double*
    space; still triggers once correctly.
  - Toggle off (default) → no behavior change at all vs. today.
  - Dictate into an app with poor/no AX support (e.g. some Electron apps,
    Terminal) → no crash, no space, silent no-op.
  - Dictate mid-IME-composition (e.g. a Pinyin/Kana candidate window open)
    → no crash; composing text isn't committed yet, so treat as no
    trustworthy cursor position → silent no-op.
  - Dictate into a rich contenteditable area in Chrome and in Safari
    (AXWebArea bridging differs between the two) → same behavior in both,
    or documented if not.
  - Dictate into a busy/hung app (simulate by picking a genuinely slow app,
    or spin the frontmost app's main thread) → Susurro's hotkey and overlay
    remain responsive; no multi-second stall.
  - Dictate into a fresh empty field → no space (nothing before cursor).
  - Password field → unaffected (secure-input path is untouched; verify the
    AX read itself also comes back empty/masked for a secure field, as
    defense in depth beyond the existing `IsSecureEventInputEnabled()` check).

## Review findings (independent review, folded in above)

An independent reviewer went over this plan before implementation started.
Two items were **blocking** and are now incorporated into the Design section
above rather than left as commentary:

1. **No AX call timeout** — the original sketch ran the AX read on the main
   thread and called that a thread-safety measure; the real risk is a
   synchronous cross-process call blocking the runloop that the hotkey's
   CGEventTap also lives on. Fixed via `AXUIElementSetMessagingTimeout` plus
   treating a timeout as just another unreadable case.
2. **Full-value read instead of bounded range** — the original step 3 read
   `kAXValueAttribute` (the whole field) first and only fell back to a
   ranged read for "large" views. Fixed by always requesting a small bounded
   slice directly.

Should-fix items also folded in: `AXValue`/`CFRange` unwrapping mechanics
spelled out explicitly (step 3); focused element obtained via
`kAXFocusedApplicationAttribute` → `kAXFocusedUIElementAttribute` rather than
system-wide → focused element directly (step 2); a test seam added for
`FocusedFieldInspector`'s own logic (Testing section); a diagnostic
`slog` line added on AX failure (step 6); IME composition, Chrome/Safari
`AXWebArea` contenteditable, and secure-field-masking added to the manual
checklist.

Not folded in as a plan change (tracked here instead, since it's not
Susurro-specific): CJK/ideographic sentence-ending punctuation (`。` `！`
`？`) isn't handled — low priority since the whisper engine in use
(`small.en`) is English-only per `ARCHITECTURE.md`.

## Out of scope / risks

- No attempt to detect or fix a selection ("replace this text") — only the
  plain-cursor case is handled; a non-empty selection is treated as
  unreadable and produces no space.
- No new permission dialog, but this is the first code in the repo that
  *reads* AX state rather than only posting keyboard events — worth a
  security-review-style second look before merging, given breadth of apps it
  will run against.
- Not scoped to fix multi-space accumulation from *pre-existing* trailing
  whitespace the user typed manually — the whitespace-trim only affects this
  feature's own decision, it does not rewrite the field's existing content.
