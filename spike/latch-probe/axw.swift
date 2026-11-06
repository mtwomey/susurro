import AppKit
// axw <bundle> <text> [bg] : write text to the focused element (optionally after Finder in front), print window title
let a=CommandLine.arguments; let app=NSRunningApplication.runningApplications(withBundleIdentifier:a[1]).first!
let el=AXUIElementCreateApplication(app.processIdentifier)
app.activate(options:[.activateIgnoringOtherApps]); usleep(600_000)
var f:CFTypeRef?; AXUIElementCopyAttributeValue(el,kAXFocusedUIElementAttribute as CFString,&f); let fe=f as! AXUIElement
if a.count>3 { NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first!.activate(options:[.activateIgnoringOtherApps]); usleep(500_000) }
if a[2]=="PID" { let src=CGEventSource(stateID:.hidSystemState); for ch in "[pid]".utf16 { var c=ch; for d in [true,false] { let e=CGEvent(keyboardEventSource:src,virtualKey:0,keyDown:d)!; e.keyboardSetUnicodeString(stringLength:1,unicodeString:&c); e.postToPid(app.processIdentifier) }; usleep(5000) } }
else { AXUIElementSetAttributeValue(fe,kAXSelectedTextAttribute as CFString,a[2] as CFString) }
usleep(500_000)
var w:CFTypeRef?; AXUIElementCopyAttributeValue(el,kAXFocusedWindowAttribute as CFString,&w)
var t:CFTypeRef?; if let w { AXUIElementCopyAttributeValue(w as! AXUIElement,kAXTitleAttribute as CFString,&t) }
var v:CFTypeRef?; AXUIElementCopyAttributeValue(fe,kAXValueAttribute as CFString,&v)
print("value=\(v as? String ?? "nil") title=\(t as? String ?? "nil")")
