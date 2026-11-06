import AppKit
import SusurroCore

/// Modal alerts shown from the status menu, moved out of AppDelegate (R4).
@MainActor
enum Alerts {
    static func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Susurro"
        let versionLine = build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
        // Model credit is required by CC-BY-4.0; shown regardless of the
        // active model since the weights ship as a menu option.
        alert.informativeText = "\(versionLine)\nMatthew Twomey\n\n\(ModelManager.parakeetAttribution)"
        // NSAlert's default icon falls back to a generic placeholder for
        // .accessory-policy (menu-bar-only, no Dock tile) apps like this one
        // — NSApp.applicationIconImage doesn't reliably resolve without a
        // Dock presence. Load the bundled icon directly instead.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            alert.icon = icon
        }
        // Clickable GitHub link as an accessory view. NSTextField opens
        // .link attributes itself once selectable — no target/action needed.
        let githubURL = "https://github.com/mtwomey/susurro"
        let link = NSTextField(labelWithAttributedString: NSAttributedString(
            string: githubURL,
            attributes: [
                .link: URL(string: githubURL)!,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        ))
        link.isSelectable = true
        link.frame = NSRect(x: 0, y: 0, width: 260, height: 18)
        alert.accessoryView = link
        alert.addButton(withTitle: "OK")
        // Licence texts of bundled code (whisper.cpp/ggml MIT, FluidAudio
        // Apache 2.0, fastcluster BSD, VBx Apache), copied into Resources by
        // `make app` from Support/ThirdPartyNotices.txt.
        let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
        if notices != nil { alert.addButton(withTitle: "Licenses…") }
        if alert.runModal() == .alertSecondButtonReturn, let notices {
            NSWorkspace.shared.open(notices)
        }
    }

    static func showAppleIntelligenceInstructions() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AI Cleanup needs Apple Intelligence"
        alert.informativeText = """
        Susurro's AI Cleanup runs entirely on your Mac using Apple Intelligence, \
        which is currently turned off.

        To enable it:
        1. Open System Settings → Apple Intelligence & Siri
        2. Turn on Apple Intelligence
        3. Wait for the model download to complete (a few minutes)

        Then click "AI Cleanup" in Susurro's menu again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            let pane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
            if let pane, NSWorkspace.shared.urlForApplication(toOpen: pane) != nil {
                NSWorkspace.shared.open(pane)
            } else if let settings = URL(string: "x-apple.systempreferences:") {
                NSWorkspace.shared.open(settings)
            }
        }
    }
}
