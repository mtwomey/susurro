// Gap probe for BEA-689 (latch go/no-go). Throwaway; not part of the build.
// The focus hop was rejected by the board and is NOT exercised here.
//
// Usage:  probe2 <bundle-id> bg     background criteria 1-4 (steals focus: target -> Finder)
//         probe2 <bundle-id> front  passive-learning spike: frontmost AX write, N trials
//         probe2 <bundle-id> read   criterion 2 only (activate target, read context, no writes)
//
// Put the caret in a THROWAWAY field of the target first. Every marker the probe
// inserts is removed again (AX restore of the original value where settable,
// otherwise backspaces posted to the pid) and the final value is compared with
// the original. Exit code 3 = cleanup could not be verified (check by hand).
import AppKit
import ApplicationServices

func ax<T>(_ e: AXUIElement, _ a: String) -> T? {
    var r: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &r) == .success, let r else { return nil }
    return r as? T
}
func axErr(_ e: AXUIElement, _ a: String) -> AXError {
    var r: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &r)
}
func value(_ e: AXUIElement) -> String? { ax(e, kAXValueAttribute) }
func range(_ e: AXUIElement) -> CFRange? {
    guard let v: AXValue = ax(e, kAXSelectedTextRangeAttribute) else { return nil }
    var r = CFRange(); return AXValueGetValue(v, .cfRange, &r) ? r : nil
}
func settable(_ e: AXUIElement, _ a: String) -> Bool {
    var s = DarwinBoolean(false); AXUIElementIsAttributeSettable(e, a as CFString, &s); return s.boolValue
}
func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?" }
func activate(_ app: NSRunningApplication) { app.activate(options: [.activateIgnoringOtherApps]) }
func waitFront(_ id: String, _ limit: Double = 2) {
    let t0 = Date()
    while front() != id && Date().timeIntervalSince(t0) < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
}
func post(_ s: String, pid: pid_t) {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in s.utf16 {
        var c = ch
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            ev.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            ev.postToPid(pid)
        }
        usleep(4000)
    }
}
func backspace(_ n: Int, pid: pid_t) {
    let src = CGEventSource(stateID: .hidSystemState)
    for _ in 0..<n { for d in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: d)!.postToPid(pid) }; usleep(6000) }
}
func sameEl(_ a: AXUIElement, _ b: AXUIElement?) -> Bool { b.map { CFEqual(a, $0) } ?? false }
func count(_ hay: String?, _ needle: String) -> Int { (hay ?? "").components(separatedBy: needle).count - 1 }

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: probe2 <bundle-id> bg|front|read"); exit(64) }
let bid = args[1], mode = args[2]
print("== \(bid) mode=\(mode) trusted=\(AXIsProcessTrusted())")
guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
      let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
else { print("not running"); exit(1) }
let pid = target.processIdentifier
let appEl = AXUIElementCreateApplication(pid)
AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
activate(target); waitFront(bid); usleep(700_000)
guard let field: AXUIElement = ax(appEl, kAXFocusedUIElementAttribute) else { print("no focused element"); exit(2) }
let role: String = ax(field, kAXRoleAttribute) ?? "?"
let orig = value(field)
let r0 = range(field)
print("field role=\(role)/\(ax(field, kAXSubroleAttribute) as String? ?? "-") valueReadable=\(orig != nil) len=\(orig?.count ?? -1) range=\(r0.map { "\($0.location),\($0.length)" } ?? "nil") selTextSettable=\(settable(field, kAXSelectedTextAttribute)) valueSettable=\(settable(field, kAXValueAttribute)) numChars=\(ax(field, kAXNumberOfCharactersAttribute) as Int? ?? -1)")
print("C2 context readable: \(orig != nil && r0 != nil ? "PASS" : "FAIL")")
if mode == "read" { exit(0) }

var dirty = false
func cleanup() -> Bool {
    // Prefer restoring the exact original value; else remove markers by backspace at the pid.
    let now = value(field)
    if now == orig { return true }
    if let orig, settable(field, kAXValueAttribute) {
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, orig as CFString); usleep(200_000)
        if let r0 { var r = r0; if let v = AXValueCreate(.cfRange, &r) { AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, v) } }
    }
    return value(field) == orig
}

if mode == "front" {
    // Passive-learning spike: target stays frontmost. AX-write a marker, read back, classify
    // all / none / partial / double. On "none" the real app would type instead; we just record.
    let n = Int(ProcessInfo.processInfo.environment["TRIALS"] ?? "10")!
    var tally = [String: Int]()
    for i in 0..<n {
        let m = "\u{2063}q\(i)z"  // invisible separator + short marker
        let before = value(field)
        let t = Date()
        let err = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, m as CFString)
        let ms = Date().timeIntervalSince(t) * 1000
        usleep(150_000)
        let after = value(field)
        let grew = (after?.count ?? 0) - (before?.count ?? 0)
        let c = count(after, m)
        let cls = c == 1 && grew == m.count ? "all" : (c == 0 && grew == 0 ? "none" : (c > 1 ? "double" : "partial"))
        tally[cls, default: 0] += 1
        print(String(format: "  trial %d err=%d %.1fms grew=%d count=%d -> %@", i, err.rawValue, ms, grew, c, cls))
        if cls != "none" { dirty = true }
        if !cleanup() && cls != "none" {
            // AX could not restore: remove by backspace while frontmost.
            backspace(max(grew, 0), pid: pid); usleep(200_000)
        }
    }
    print("FRONT tally \(tally)  frontNow=\(front())")
    let ok = value(field) == orig
    print("cleanup verified=\(ok)"); exit(ok ? 0 : 3)
}

// mode == "bg": criteria 1, 3, 4(undo) with Finder in front.
activate(finder); waitFront("com.apple.finder"); usleep(400_000)
let staleAfterSwitch = axErr(field, kAXRoleAttribute) == .invalidUIElement
let r1 = range(field)
print("C3 element valid after focus moved: \(!staleAfterSwitch ? "PASS" : "FAIL")  caret before=\(r0.map { "\($0.location)" } ?? "nil") after=\(r1.map { "\($0.location)" } ?? "nil") \(r0?.location == r1?.location ? "PASS" : "FAIL")")

// C1a AX write
let mAX = "[ax]"
let e = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, mAX as CFString)
usleep(300_000)
let vAX = value(field), rAX = range(field)
let axLanded = count(vAX, mAX) == 1
print("C1 AX write err=\(e.rawValue) landed=\(axLanded) caretAfter=\(rAX.map { "\($0.location)" } ?? "nil") front=\(front())")
if axLanded { dirty = true }

// C1b postToPid, only if the app's focused element is still the remembered one (latch invariant)
let focusedNow: AXUIElement? = ax(appEl, kAXFocusedUIElementAttribute)
let invariant = sameEl(field, focusedNow)
let mPID = "[pid]"
var pidLanded = false
if invariant {
    post(mPID, pid: pid); usleep(400_000)
    pidLanded = count(value(field), mPID) == 1
    if pidLanded { dirty = true }
}
print("C1 postToPid invariant(focused==remembered)=\(invariant) landed=\(pidLanded) front=\(front())")

// C4 undo: Cmd+Z posted to pid once; does it remove exactly the last marker?
if axLanded || pidLanded {
    let pre = value(field)
    let src = CGEventSource(stateID: .hidSystemState)
    for d in [true, false] { let ev = CGEvent(keyboardEventSource: src, virtualKey: 6, keyDown: d)!; ev.flags = .maskCommand; ev.postToPid(pid) }
    usleep(400_000)
    let post1 = value(field)
    print("C4 undo(bg Cmd+Z): before=…\(String((pre ?? "").suffix(20))) after=…\(String((post1 ?? "").suffix(20))) axGone=\(count(post1, mAX) == 0) pidGone=\(count(post1, mPID) == 0)")
}
print("stillFront=\(front())  stale-at-end=\(axErr(field, kAXRoleAttribute) == .invalidUIElement)")
var ok = cleanup()
if !ok && dirty {
    // Background backspace fallback for non-settable fields (terminals etc.).
    let extra = (value(field)?.count ?? 0) - (orig?.count ?? 0)
    if extra > 0 && invariant { backspace(extra, pid: pid); usleep(300_000) }
    ok = value(field) == orig
}
print("cleanup verified=\(ok)  (len now=\(value(field)?.count ?? -1) orig=\(orig?.count ?? -1))")
exit(ok ? 0 : 3)
