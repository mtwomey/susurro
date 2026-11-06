// BEA-689 chord sanity: listen-only CGEventTap. Logs flagsChanged/keyDown so we can see
// whether Cmd taps arrive cleanly while rightOption (PTT) is held. Listen-only: it never
// swallows events and does not touch the installed Susurro app.
// Usage: chordtap [seconds]   (default 20)
import AppKit
let secs = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
var rOptDown = false
let cb: CGEventTapCallBack = { _, type, ev, _ in
    let code = ev.getIntegerValueField(.keyboardEventKeycode)
    let f = ev.flags
    if type == .flagsChanged && code == 61 { rOptDown = f.contains(.maskAlternate) }
    let names: [Int64: String] = [54: "rCmd", 55: "lCmd", 58: "lOpt", 61: "rOpt"]
    print(String(format: "%.3f %@ key=%@ cmd=%d opt=%d pttHeld=%d front=%@", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000),
                 type == .flagsChanged ? "flags" : (type == .keyDown ? "down " : "up   "), names[code] ?? "\(code)",
                 f.contains(.maskCommand) ? 1 : 0, f.contains(.maskAlternate) ? 1 : 0, rOptDown ? 1 : 0,
                 NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))
    fflush(stdout)
    return Unmanaged.passUnretained(ev)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                  eventsOfInterest: mask, callback: cb, userInfo: nil)
else { print("tapCreate failed (Input Monitoring permission?)"); exit(1) }
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("listening \(Int(secs))s: hold rightOption, tap Cmd a few times, release"); fflush(stdout)
CFRunLoopRunInMode(.defaultMode, secs, false)
