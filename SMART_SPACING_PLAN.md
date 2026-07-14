# Smart Spacing — feature plan

> Status: **planned, not yet built.** Companion to `ARCHITECTURE.md` (as-built
> structure) and `PLAN.md` (v1 historical design doc). This is a focused plan
> for one v2 feature: read the parking lot in `PLAN.md` for how it was queued.

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

**New file: `Sources/SusurroCore/FocusedFieldInspector.swift`**

```swift
enum FocusedFieldInspector {
    /// Returns the last non-whitespace character immediately before the
    /// insertion point in the system's focused text element, or nil if
    /// unreadable (no focused element, non-text role, AX error, empty text
    /// before cursor, etc). Never throws; failure is nil.
    static func lastNonWhitespaceCharBeforeCursor() -> Character?
}
```

Implementation sketch:
1. `AXUIElementCreateSystemWide()` → copy `kAXFocusedUIElementAttribute` →
   the focused `AXUIElement`.
2. Read `kAXSelectedTextRangeAttribute` (an `AXValue` wrapping a `CFRange`)
   for the cursor position (empty-length range = plain cursor, not a
   selection — a non-empty selection means "replace," which is out of scope
   for this heuristic; treat as unreadable/no-op).
3. Read `kAXValueAttribute` (the field's full string) — some elements only
   support a bounded read via `kAXStringForRangeParameterizedAttribute` for
   large text views; fall back to that if `kAXValueAttribute` isn't a plain
   string.
4. Take the substring ending at the cursor offset, trim trailing
   whitespace/newlines, return the last character (or nil if empty/any AX
   call fails).

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
  - Dictate into a fresh empty field → no space (nothing before cursor).
  - Password field → unaffected (secure-input path is untouched; this
    feature never sees secure-input text either).

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
