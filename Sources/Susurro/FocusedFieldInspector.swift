import ApplicationServices
import Foundation

/// Reads a short slice of text immediately before the text-insertion cursor
/// in whatever UI element currently has keyboard focus, system-wide.
///
/// This is the first code in the app that *reads* Accessibility state rather
/// than only posting synthetic keyboard events (contrast `TextInjector`,
/// `HotkeyMonitor`). It backs Smart Spacing (see SMART_SPACING_PLAN.md) and
/// must never throw, never block for long, and never surface an error to the
/// user: any failure — no focused app/element, wrong role, a real selection
/// instead of a plain cursor, an AX error or timeout — is silently `nil`,
/// which the caller (`SpacingRule`) maps to "do nothing."
///
/// Runs on the main thread by design (`@MainActor`): AX round-trips are
/// synchronous cross-process calls, and doing this off-thread would just
/// move the same blocking risk to a different thread without eliminating
/// it. `AXUIElementSetMessagingTimeout` bounds the worst case so a
/// busy/hung frontmost app can't stall Susurro's own runloop — the one
/// `HotkeyMonitor`'s CGEventTap also lives on.
@MainActor
enum FocusedFieldInspector {
    /// Characters of context pulled back from the cursor. Kept small: Smart
    /// Spacing only ever needs the last non-whitespace character, or a
    /// sentence-ender + closing quote/paren pair. A bounded read is cheaper
    /// than reading the whole field and avoids momentarily holding more of a
    /// field's content than necessary — some fields carry sensitive text
    /// even outside a secure field.
    private static let contextLength = 8

    private static let messagingTimeoutSeconds: Float = 0.15

    /// Returns up to `contextLength` raw characters immediately before the
    /// insertion point of the system's focused text element, or nil if
    /// unreadable for any reason. Trailing-whitespace trimming and the
    /// sentence-ender decision both happen in `SpacingRule`, not here.
    static func textBeforeCursor() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeoutSeconds)

        // Two-step lookup (system-wide → focused *application* → focused
        // *element* within it) is more reliable across apps than asking the
        // system-wide element for the focused element directly.
        guard let focusedApp = copyElementAttribute(systemWide, kAXFocusedApplicationAttribute) else {
            slog("smart spacing: no focused application via AX")
            return nil
        }
        AXUIElementSetMessagingTimeout(focusedApp, messagingTimeoutSeconds)

        guard let element = copyElementAttribute(focusedApp, kAXFocusedUIElementAttribute) else {
            slog("smart spacing: no focused element via AX")
            return nil
        }
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)

        guard let range = selectedTextRange(of: element) else {
            slog("smart spacing: no readable selected-text range")
            return nil
        }
        // A non-empty selection means "the next dictation would replace
        // this," which is a different feature; treat it as unreadable here.
        guard range.length == 0, range.location > 0 else { return nil }

        let start = max(0, range.location - contextLength)
        let length = range.location - start
        guard length > 0 else { return nil }

        guard let text = boundedString(of: element, location: start, length: length), !text.isEmpty else {
            slog("smart spacing: bounded string-for-range read failed or empty")
            return nil
        }
        return text
    }

    // MARK: - AX plumbing

    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        )
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func boundedString(of element: AXUIElement, location: Int, length: Int) -> String? {
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        )
        guard status == .success else { return nil }
        return value as? String
    }
}
