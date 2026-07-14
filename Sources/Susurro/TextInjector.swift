import CoreGraphics
import Foundation

/// Types text into the focused application by posting CGEvents.
/// Replaces the Python version's osascript keystroke injection —
/// no shell escaping, handles unicode, and supports newlines properly.
enum TextInjector {
    private static let returnKeyCode: CGKeyCode = 36
    /// keyboardSetUnicodeString reliably delivers ~20 UTF-16 units per event.
    private static let maxChunkUTF16 = 18

    /// Types `text` into the focused app. Returns `false` if any keystroke
    /// event couldn't be constructed/posted (e.g. no Accessibility/Input
    /// Monitoring permission) — callers that track "what did we just type"
    /// (Smart Spacing) should treat a `false` result as "nothing happened."
    @discardableResult
    static func type(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var ok = true

        for (index, line) in lines.enumerated() {
            if index > 0 { ok = pressReturn(source: source) && ok }
            var remaining = Substring(line)
            while !remaining.isEmpty {
                let chunk = String(remaining.prefix(maxChunkUTF16))
                remaining = remaining.dropFirst(chunk.count)
                ok = post(chunk: chunk, source: source) && ok
            }
        }
        return ok
    }

    @discardableResult
    private static func post(chunk: String, source: CGEventSource?) -> Bool {
        let utf16 = Array(chunk.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(2_000) // small settle time between chunks
        return true
    }

    @discardableResult
    private static func pressReturn(source: CGEventSource?) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(2_000)
        return true
    }
}
