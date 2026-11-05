import AppKit
import ApplicationServices
import Carbon
import SusurroCore

/// Reads the focused text field through Accessibility for the pre-insert
/// text-handling stage (BEA-648, docs/TEXT_HANDLING_FINDINGS.md §3.2 B).
///
/// Called when push-to-talk is released and run concurrently with
/// transcription, so its latency is off the critical path; the whole read is
/// capped (default 250 ms) and returns nil on timeout. Secure fields are
/// detected by role/subrole and never read. Field text is returned to the
/// caller only and must never be logged.
enum FocusedFieldReader {
    /// Electron apps expose no AX tree until this is set on the app element.
    private static let manualAccessibility = "AXManualAccessibility"
    nonisolated(unsafe) private static var enabledPIDs = Set<pid_t>()
    private static let lock = NSLock()

    static func read(pid: pid_t, cap: Duration = .milliseconds(250)) async -> FieldRead? {
        await withTaskGroup(of: FieldRead??.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: readNow(pid: pid))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: cap)
                return .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// Synchronous read; blocking AX IPC, so never call on the main thread.
    static func readNow(pid: pid_t) -> FieldRead? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        enableManualAccessibilityOnce(app: app, pid: pid)

        guard let focused: AXUIElement = copy(app, kAXFocusedUIElementAttribute) else {
            return FieldRead(before: nil, after: nil, detail: "noFocusedElement")
        }
        AXUIElementSetMessagingTimeout(focused, 0.2)

        let role: String? = copy(focused, kAXRoleAttribute)
        let subrole: String? = copy(focused, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) {
            return .secureField
        }
        if IsSecureEventInputEnabled() { return .secureField }

        let value: String? = copy(focused, kAXValueAttribute)

        // Native text views: whole value + CFRange selection.
        if let value, let range = selectedRange(focused) {
            var read = FieldRead.fromValue(value, location: range.location, length: range.length)
            read.detail += " role=\(role ?? "?")"
            return read
        }

        // An empty value settles the empty-field case (stray leading space
        // after Enter-to-send) even where the cursor is unreadable.
        if let value, value.isEmpty {
            return FieldRead(before: "", after: "", detail: "emptyValue role=\(role ?? "?")")
        }

        // Chromium / WebKit / Electron: text markers. The marker start may be
        // the document start rather than the field start, so when the value
        // is known the result must be a prefix of it; otherwise fall back.
        if let before = textBeforeSelectionViaMarkers(focused),
           value == nil || value!.hasPrefix(before) {
            return FieldRead(before: before, after: value.map { String($0.dropFirst(before.count)) },
                             detail: "markers beforeLen=\(before.count) role=\(role ?? "?")")
        }
        // Whole buffer, no cursor (Warp, Terminal): keep the end of the value
        // for the BufferTail heuristic, which needs the memory anchor.
        return FieldRead(before: nil, after: nil,
                         detail: "unreadable role=\(role ?? "?") hasValue=\(value != nil)",
                         bufferTail: value.map { String($0.suffix(512)) })
    }

    private static func enableManualAccessibilityOnce(app: AXUIElement, pid: pid_t) {
        lock.lock()
        let isNew = enabledPIDs.insert(pid).inserted
        lock.unlock()
        guard isNew else { return }
        // Harmless on apps that don't recognise it; Electron/Chromium build
        // their AX tree in response. Not AXEnhancedUserInterface: that one
        // disturbs window animations and window managers.
        AXUIElementSetAttributeValue(app, manualAccessibility as CFString, kCFBooleanTrue)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        return ref as? T
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location != kCFNotFound else { return nil }
        return range
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &ref) == .success
        else { return nil }
        return ref
    }

    /// Text from the start of the field to the selection start, using the
    /// WebKit/Chromium text-marker API.
    private static func textBeforeSelectionViaMarkers(_ element: AXUIElement) -> String? {
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &selection) == .success,
              let selection,
              let caret = parameterized(element, "AXStartTextMarkerForTextMarkerRange", selection) else { return nil }
        var fieldStart: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXStartTextMarker" as CFString, &fieldStart) == .success,
              let fieldStart else { return nil }
        let pair = [fieldStart, caret] as CFArray
        guard let range = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", pair),
              let text = parameterized(element, "AXStringForTextMarkerRange", range) as? String
        else { return nil }
        return text
    }
}
