import Foundation

/// Tracks what Susurro itself most recently typed and into which app, so
/// Smart Spacing can decide whether to prepend a leading space to the next
/// dictation — without reading the target app's UI at all.
///
/// This replaces an earlier Accessibility-based design (see
/// docs/SMART_SPACING_PLAN.md's "Pivot" section): `kAXSelectedTextRangeAttribute`,
/// the standard way to ask "where's the cursor," is only reliably
/// implemented by native Cocoa text views (TextEdit, Notes, Mail). Electron
/// apps and Chromium/WebKit web content expose cursor position through an
/// entirely different, non-standard mechanism (`AXTextMarkerRange`), and
/// Terminal's custom-drawn text view doesn't expose per-character selection
/// via AX at all — so the AX approach silently did nothing in exactly the
/// places dictation happens most (chat apps, terminals, browser fields).
/// Self-tracking has no such gap: it works in anything Susurro can type
/// into, at the cost of not noticing if the user manually edits the field
/// (or switches to a different window in the *same* app) between
/// dictations.
public struct DictationMemory {
    // SpacingRule only ever looks at the single character immediately
    // before the cursor.
    private static let contextLength = 1

    private var last: (pid: pid_t, tail: String)?

    public init() {}

    /// Call after successfully typing `text` into the frontmost app (`pid`).
    public mutating func recordTyped(_ text: String, intoPID pid: pid_t) {
        last = (pid, String(text.suffix(Self.contextLength)))
    }

    /// Call when nothing was actually typed (e.g. a secure field silently
    /// blocked it) — clears the memory so a stale tail can't leak into
    /// whatever field is focused next.
    public mutating func clear() {
        last = nil
    }

    /// The tail Susurro itself last typed, but only if `pid` (the currently
    /// frontmost app) matches where it was typed. nil if nothing's been
    /// typed yet, or the user has since switched to a different app.
    public func tailIfStillFocused(pid: pid_t) -> String? {
        guard let last, last.pid == pid else { return nil }
        return last.tail
    }
}
