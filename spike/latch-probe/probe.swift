// Throwaway probe for BEA-678 (latch feasibility). Not part of the build.
// Usage: swift probe.swift <bundle-id> [skipwrite]
// 1. Activates the target and remembers its focused AX element.
// 2. Activates Finder (the "user's other app").
// 3. Tries background delivery: AX kAXSelectedText write, then CGEvent.postToPid.
// 4. Measures a focus hop (activate target, type via HID tap, reactivate Finder).
// After each method, reads the remembered element's AXValue back to see if
// the marker landed, and checks the frontmost app never changed unexpectedly.
import AppKit
import ApplicationServices

func ax<T>(_ e: AXUIElement, _ a: String) -> T? {
    var r: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &r) == .success, let r else { return nil }
    return r as? T
}
func value(_ e: AXUIElement) -> String { (ax(e, kAXValueAttribute) as String?) ?? "<nil>" }
func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?" }
func activate(_ app: NSRunningApplication) { app.activate(options: [.activateIgnoringOtherApps]) }
func waitFront(_ id: String, _ limit: Double = 2) -> Double {
    let t0 = Date()
    while front() != id && Date().timeIntervalSince(t0) < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    return Date().timeIntervalSince(t0) * 1000
}
func type(_ s: String, pid: pid_t?) {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in s.utf16 {
        var c = ch
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            ev.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            if let pid { ev.postToPid(pid) } else { ev.post(tap: .cghidEventTap) }
        }
        usleep(4000)
    }
}

let args = CommandLine.arguments
let bid = args[1]
let skipWrite = args.count > 2 && args[2] == "skipwrite"
print("== \(bid)  trusted=\(AXIsProcessTrusted())")
guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
      let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
else { print("not running"); exit(1) }
let appEl = AXUIElementCreateApplication(target.processIdentifier)
AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
activate(target); _ = waitFront(bid); usleep(700_000)
guard let field: AXUIElement = ax(appEl, kAXFocusedUIElementAttribute) else { print("no focused element"); exit(2) }
var settable = DarwinBoolean(false)
AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable)
let role: String = ax(field, kAXRoleAttribute) ?? "?"
let sub: String = ax(field, kAXSubroleAttribute) ?? "-"
print("field role=\(role)/\(sub) selTextSettable=\(settable.boolValue) value.len=\(value(field).count)")
let before = value(field)
if skipWrite { exit(0) }

activate(finder); print("finder front after \(Int(waitFront("com.apple.finder")))ms"); usleep(400_000)

// 1. AX write
let t1 = Date()
let err = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, "[ax]" as CFString)
let axMs = Date().timeIntervalSince(t1) * 1000
usleep(300_000)
let v1 = value(field)
print(String(format: "AX setSelectedText err=%d %.1fms landed=%@ front=%@", err.rawValue, axMs,
             v1.contains("[ax]") ? "YES" : "no", front()))

// 2. postToPid
type("[pid]", pid: target.processIdentifier); usleep(400_000)
let v2 = value(field)
print("postToPid landed=\(v2.contains("[pid]") ? "YES" : "no") front=\(front())")

// 3. focus hop
let t3 = Date()
activate(target); let inMs = waitFront(bid); usleep(UInt32(ProcessInfo.processInfo.environment["HOP_SETTLE_US"] ?? "80000")!)
// Restore remembered element focus (may be needed if app focus moved).
AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
type("[hop]", pid: nil)
activate(finder); let outMs = waitFront("com.apple.finder")
let hopMs = Date().timeIntervalSince(t3) * 1000
usleep(300_000)
let v3 = value(field)
print(String(format: "focusHop landed=%@ activateIn=%.0fms back=%.0fms total=%.0fms front=%@",
             v3.contains("[hop]") ? "YES" : "no", inMs, outMs, hopMs, front()))
print("value delta: \(String(v3.dropFirst(max(0, before.count - 5))).prefix(80))")
