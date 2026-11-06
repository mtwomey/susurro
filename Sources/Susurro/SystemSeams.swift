import AppKit
import Carbon
import SusurroCore

/// The real Inserter: CGEvent keystrokes via TextInjector (BEA-665).
@MainActor
final class KeystrokeInserter: Inserter {
    func type(_ text: String) -> Bool { TextInjector.type(text) }
    func deleteBackward(_ count: Int) { TextInjector.deleteBackward(count) }
}

/// The real Clipboard: NSPasteboard.general.
@MainActor
final class GeneralPasteboard: Clipboard {
    func set(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The real FrontmostAppProvider: NSWorkspace + Carbon secure-input state.
@MainActor
final class SystemFrontmostApp: FrontmostAppProvider {
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var secureInputActive: Bool { IsSecureEventInputEnabled() }
}
