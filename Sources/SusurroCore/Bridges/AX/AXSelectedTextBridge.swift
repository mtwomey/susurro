import ApplicationServices
import Foundation

/// Latch through Accessibility: `kAXSelectedText` write on the element
/// focused at latch time, re-validated before each chunk, read back from
/// the value. Registered but NOT allowlisted for any app: TextEdit's in-app
/// undo check failed (one Cmd+Z removes every latched chunk; BEA-691).
public struct AXSelectedTextBridge: LatchingBridge {
    public let id = BridgeID.axSelectedText
    /// Serves whatever the allowlist names for this bridge; none today.
    public let bundleIDs: Set<String> = []
    public let documentNoun = "document"

    public init() {}

    public func pin(_ request: LatchPinRequest) throws(BridgeError) -> any LatchTarget {
        guard let target = AXSelectedTextLatchTarget(request: request, documentNoun: documentNoun) else {
            throw .noTarget
        }
        return target
    }
}

/// @unchecked: holds an AXUIElement (a CF type, safe to message from any
/// thread); all other state is immutable.
public final class AXSelectedTextLatchTarget: LatchTarget, @unchecked Sendable {
    public let pin: LatchPin
    private let element: AXUIElement
    private let pid: pid_t

    init?(request: LatchPinRequest, documentNoun: String) {
        let app = AXUIElementCreateApplication(request.pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard Self.string(element, kAXRoleAttribute) == kAXTextAreaRole as String else { return nil }
        var window: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window)
        let title = window.flatMap { w in CFGetTypeID(w) == AXUIElementGetTypeID() ? Self.string(w as! AXUIElement, kAXTitleAttribute) : nil }
        self.element = element
        self.pid = request.pid
        self.pin = LatchPin(method: .axSelectedText, bundleID: request.bundleID, appName: request.appName,
                            documentName: title ?? "document", handle: String(request.pid), documentNoun: documentNoun)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func selection() -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Re-validate: same process, still a text area with a window.
    private func alive() -> Bool {
        var p: pid_t = 0
        guard AXUIElementGetPid(element, &p) == .success, p == pid,
              Self.string(element, kAXRoleAttribute) == kAXTextAreaRole as String else { return false }
        var window: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success
    }

    public func context() -> LatchBridgeReply {
        guard alive() else { return .gone }
        guard let value = Self.string(element, kAXValueAttribute), let sel = selection() else { return .unavailable }
        let ns = value as NSString
        let start = max(0, min(sel.location, ns.length) - 200)
        return .value(ns.substring(with: NSRange(location: start, length: min(sel.location, ns.length) - start)))
    }

    public func insert(_ text: String) -> LatchBridgeReply {
        guard alive() else { return .gone }
        guard let sel = selection(),
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
              let value = Self.string(element, kAXValueAttribute) else { return .unavailable }
        let ns = value as NSString
        let len = (text as NSString).length
        guard sel.location + len <= ns.length else { return .value("") }
        return .value(ns.substring(with: NSRange(location: sel.location, length: len)))
    }

    public func release() {}
}
