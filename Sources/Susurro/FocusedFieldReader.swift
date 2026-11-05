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

    static func read(pid: pid_t, bundleID: String?, cap: Duration = .milliseconds(250)) async -> FieldSnapshot? {
        // A real cap (BEA-663, F5): a task group would wait for the
        // non-cancellable AX child; this returns nil at the cap and drops a
        // late result.
        await CappedRead.run(cap: cap) { readNow(pid: pid, bundleID: bundleID) }
    }

    /// Synchronous read; blocking AX IPC, so never call on the main thread.
    /// Collects raw facts only — interpretation is the `ContextProvider`s' job
    /// (SusurroCore/ContextProviders.swift).
    static func readNow(pid: pid_t, bundleID: String?) -> FieldSnapshot {
        if IsSecureEventInputEnabled() { return .secureField }
        // Per-app bridge first, only for its own app; when it answers, the
        // Accessibility read is skipped entirely.
        if let bridge = AppBridges.bridge(for: bundleID), let before = bridge.textBeforeCursor() {
            return FieldSnapshot(appBefore: before, appBridge: bridge.name)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        enableManualAccessibilityOnce(app: app, pid: pid)

        guard let focused: AXUIElement = copy(app, kAXFocusedUIElementAttribute) else { return .nothing }
        AXUIElementSetMessagingTimeout(focused, 0.2)

        let role: String? = copy(focused, kAXRoleAttribute)
        let subrole: String? = copy(focused, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String)
            || IsSecureEventInputEnabled() {
            return .secureField
        }
        let value: String? = copy(focused, kAXValueAttribute)
        let selection = selectedRange(focused).map { NSRange(location: $0.location, length: $0.length) }
        let markerBefore = selection == nil ? textBeforeSelectionViaMarkers(focused) : nil
        return FieldSnapshot(value: value, selection: selection, markerBefore: markerBefore, role: role).sanitized
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
