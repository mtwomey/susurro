import CoreGraphics
import Foundation

/// Types text into the focused application by posting CGEvents.
/// Replaces the Python version's osascript keystroke injection —
/// no shell escaping, handles unicode, and supports newlines properly.
enum TextInjector {
    private static let returnKeyCode: CGKeyCode = 36
    /// keyboardSetUnicodeString reliably delivers ~20 UTF-16 units per event.
    private static let maxChunkUTF16 = 18

    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() {
            if index > 0 { pressReturn(source: source) }
            var remaining = Substring(line)
            while !remaining.isEmpty {
                let chunk = String(remaining.prefix(maxChunkUTF16))
                remaining = remaining.dropFirst(chunk.count)
                post(chunk: chunk, source: source)
            }
        }
    }

    private static func post(chunk: String, source: CGEventSource?) {
        let utf16 = Array(chunk.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(2_000) // small settle time between chunks
    }

    private static func pressReturn(source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(2_000)
    }
}
