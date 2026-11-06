import AppKit
let app=NSRunningApplication.runningApplications(withBundleIdentifier:CommandLine.arguments[1]).first!
let el=AXUIElementCreateApplication(app.processIdentifier)
func foc()->String{var f:CFTypeRef?;let e=AXUIElementCopyAttributeValue(el,kAXFocusedUIElementAttribute as CFString,&f); guard e == .success else {return "err \(e.rawValue)"}; var r:CFTypeRef?;AXUIElementCopyAttributeValue(f as! AXUIElement,kAXRoleAttribute as CFString,&r); return r as? String ?? "?"}
app.activate(options:[.activateIgnoringOtherApps]); usleep(600_000); print("front: focused=\(foc())")
NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first!.activate(options:[.activateIgnoringOtherApps]); usleep(500_000); print("background: focused=\(foc())")
