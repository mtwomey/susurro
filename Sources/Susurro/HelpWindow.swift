import AppKit

/// Lightweight help: one window, plain descriptions of the hotkey and each
/// menu item. Non-modal so it can stay open while exploring the menu.
@MainActor
final class HelpWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let text = NSMutableAttributedString()

        func heading(_ s: String) {
            text.append(NSAttributedString(
                string: s + "\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 15),
                    .foregroundColor: NSColor.labelColor,
                ]
            ))
        }
        func body(_ s: String) {
            text.append(NSAttributedString(
                string: s + "\n\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                ]
            ))
        }

        heading("Dictating")
        body("""
        Hold your push-to-talk key (default: Right Option), speak, release. \
        Your words are typed into whatever app has focus. While recording, a \
        small waveform pill appears in the bottom-right corner.
        """)

        heading("Start Test Recording")
        body("""
        Record without the hotkey: click to start, click again to stop. The \
        transcript goes to the clipboard only (nothing is typed). Handy for \
        testing your microphone or a new model.
        """)

        heading("Edit Rules…")
        body("""
        Opens your rules file (rules.json). It controls spoken punctuation \
        ("comma", "period", "quote … end quote", "new line"), custom word \
        fix-ups for words Susurro mishears, and advanced regex rules. Edits \
        apply on your next dictation — no restart needed. The file explains \
        its own format at the top.
        """)

        heading("Model")
        body("""
        Choose the speech-recognition model. Smaller models are faster but \
        less accurate; small.en is the recommended balance. Click an \
        undownloaded model to download it — Susurro switches to it \
        automatically and notifies you when it's ready. The checkmark shows \
        the active model.
        """)

        heading("Push-to-Talk Key")
        body("""
        Pick which key you hold to dictate: Right Option, Right Command, or \
        Right Control. Takes effect immediately.
        """)

        heading("AI Cleanup")
        body("""
        Optional grammar-and-punctuation pass over your transcript using \
        Apple Intelligence, entirely on this Mac. It fixes capitalization and \
        obvious errors and removes filler words, without rewording you. Adds \
        roughly a second on longer dictations; very short dictations skip it. \
        Requires macOS 26 with Apple Intelligence enabled — if it's off, this \
        menu item walks you through enabling it.
        """)

        heading("Copy Transcript to Clipboard")
        body("""
        When checked, every transcript is also copied to the clipboard. Off \
        by default so dictating never overwrites something you were about to \
        paste. Exception: if a password field or other secure input blocks \
        the typing, the transcript is copied regardless, so your words aren't \
        lost.
        """)

        heading("Smart Spacing")
        body("""
        Off by default. When checked, dictating again right after Susurro \
        typed something adds a leading space (unless one's already there), \
        so back-to-back dictations into the same field don't run together. \
        Susurro tracks this itself — it doesn't read the field's contents — \
        so it only applies if you haven't switched to a different app since \
        your last dictation, and it won't notice text you typed by hand in \
        between.
        """)

        heading("Start at Login")
        body("""
        When checked, Susurro launches automatically when you log in.
        """)

        heading("Recording indicators")
        body("""
        While the microphone is live, macOS shows an orange dot and a \
        microphone pill in the menu bar. These are system privacy indicators \
        shown for every app that records audio; they disappear when you \
        release the key.
        """)

        heading("System permissions")
        body("""
        Susurro needs two permissions, both under System Settings → Privacy & \
        Security:

        •  Microphone — to hear you. Requested automatically on first launch.

        •  Accessibility — to watch for the push-to-talk key and to type the \
        transcript into other apps. macOS prompts for this once; after \
        granting it, quit and relaunch Susurro.

        Optionally, allow Notifications so Susurro can tell you when a model \
        download finishes. If dictation ever stops working, check that both \
        permissions are still granted — macOS revokes Accessibility if the \
        app is moved or reinstalled.
        """)

        let textView = NSTextView()
        textView.textStorage?.setAttributedString(text)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Susurro Help"
        window.contentView = scroll
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
