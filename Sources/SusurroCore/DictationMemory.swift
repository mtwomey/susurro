import Foundation

/// Tracks what Susurro itself most recently typed and into which app, so
/// Smart Spacing can decide whether to prepend a leading space to the next
/// dictation — without reading the target app's UI at all.
///
/// This replaces an earlier Accessibility-based design (see
/// docs/history/SMART_SPACING_PLAN.md's "Pivot" section): `kAXSelectedTextRangeAttribute`,
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
    // The text-handling stage looks at the last few characters (whitespace,
    // closing quotes, sentence-ending punctuation) before the cursor.
    // Kept short: this is the fallback when Accessibility can't read the field.
    private static let contextLength = 16

    private var last: (pid: pid_t, tail: String, position: ValuePosition?)?

    public init() {}

    /// Call after successfully typing `text` into the frontmost app (`pid`).
    /// `position` is where the insertion ended inside the field's value, when
    /// the value (but not the cursor) was readable — see `AnchoredValueProvider`.
    /// `continuesTail`: false when the insertion point was unknown (the user
    /// may have deleted or moved away from the old tail), so the old tail is
    /// not glued in front of the new text.
    public mutating func recordTyped(_ text: String, intoPID pid: pid_t, position: ValuePosition? = nil,
                                     continuesTail: Bool = true) {
        // Same app: the new text continues the old tail (a very short
        // dictation like "ok" still needs to know what preceded it).
        let combined = (continuesTail && last?.pid == pid ? last!.tail : "") + text
        last = (pid, String(combined.suffix(Self.contextLength)), position)
    }

    /// Call after deleting `count` characters Susurro itself typed (a shown
    /// hands-free end mark retracted with Backspace, BEA-657).
    public mutating func recordDeletedBackward(_ count: Int, inPID pid: pid_t) {
        guard let current = last, current.pid == pid, count > 0 else { return }
        let position = current.position.map {
            ValuePosition(caretOffset: max(0, $0.caretOffset - count), valueLength: max(0, $0.valueLength - count))
        }
        last = (pid, String(current.tail.dropLast(count)), position)
    }

    /// What Susurro last typed into this app, plus where, if known.
    public func insertionIfStillFocused(pid: pid_t) -> RememberedInsertion? {
        guard let last, last.pid == pid else { return nil }
        return RememberedInsertion(tail: last.tail, position: last.position)
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

/// Where an insertion ended inside a field's value (UTF-16 offsets), and how
/// long the value was right after it.
public struct ValuePosition: Sendable, Equatable {
    /// Position after typing `typed` at the end of `before` (the text before
    /// the cursor, read from `value`), having first deleted `deletedBackward`
    /// characters with Backspace (a retracted full stop, BEA-677).
    public static func afterInsertion(before: String, value: String, typed: String,
                                      deletedBackward: Int = 0) -> ValuePosition {
        let typedLength = (typed as NSString).length
        return ValuePosition(caretOffset: max(0, (before as NSString).length - deletedBackward) + typedLength,
                             valueLength: max(0, (value as NSString).length - deletedBackward) + typedLength)
    }

    public var caretOffset: Int
    public var valueLength: Int
    public init(caretOffset: Int, valueLength: Int) {
        self.caretOffset = caretOffset
        self.valueLength = valueLength
    }
}

/// Susurro's memory of its last insertion into the focused app.
public struct RememberedInsertion: Sendable, Equatable {
    public var tail: String
    public var position: ValuePosition?
    public init(tail: String, position: ValuePosition? = nil) {
        self.tail = tail
        self.position = position
    }
}
