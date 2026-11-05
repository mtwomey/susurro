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

        heading("Model")
        body("""
        Choose the speech-recognition model. Each entry shows its download \
        size and what it's good for, grouped by engine:

        •  Whisper (whisper.cpp) — five sizes. Smaller models are faster but \
        less accurate; small.en is the default and the recommended balance. \
        large-v3-turbo is the only model that understands languages other \
        than English.

        •  NVIDIA Parakeet (Apple Silicon only) — parakeet-tdt-v2, English \
        only. The most accurate option, and faster than small.en. Hidden on \
        Intel Macs.

        Click an undownloaded model to download it; the entry shows the \
        percentage while it downloads. Susurro keeps using the current model \
        until the new one is ready, then switches to it automatically and \
        notifies you. Click a downloaded model to switch to it instantly. \
        The checkmark shows the active model.
        """)

        heading("Push-to-Talk Key")
        body("""
        Pick which key you hold to dictate: Right Option, Right Command, or \
        Right Control. Takes effect immediately.
        """)

        heading("Hands-Free")
        body("""
        For longer passages: hold your push-to-talk key, tap the latch key \
        (default: Right Command; Right Option if push-to-talk is Right \
        Command), then let go and keep talking. The overlay turns blue and \
        says HANDS-FREE. Text is typed at each pause. Tap the push-to-talk \
        key to stop, or press Esc to discard what hasn't been typed yet. \
        Hands-free stops by itself after 60 seconds without speech, after \
        two hours, or when you switch apps. Change the latch key in \
        Hands-Free Latch Key.
        """)

        heading("Start at Login")
        body("""
        When checked, Susurro launches automatically when you log in.
        """)

        heading("Smart Spacing")
        body("""
        Off by default. When checked, Susurro looks at the text just before \
        the cursor so new words fit in: one space between sentences, never \
        a stray leading or double space, and lower-case when you're \
        continuing a sentence. Password fields are never read, and field \
        text is never stored or logged. Where a field can't be read, \
        Susurro falls back to remembering what it last typed.
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

        heading("About Susurro")
        body("""
        Shows the installed version number, author, a link to the project \
        on GitHub, and the licence credit for the NVIDIA Parakeet model \
        (CC-BY-4.0).
        """)

        heading("Edit Rules…")
        body("""
        Opens your rules file (rules.json). It controls spoken punctuation \
        ("comma", "period", "quote … end quote", "new line"), custom word \
        fix-ups for words Susurro mishears, and advanced regex rules. Edits \
        apply on your next dictation — no restart needed. The file explains \
        its own format at the top.
        """)

        heading("Recording indicators")
        body("""
        While the microphone is live, macOS shows an orange dot and a \
        microphone pill in the menu bar. These are system privacy indicators \
        shown for every app that records audio; they disappear when you \
        release the key.
        """)

        heading("Menu bar icon")
        body("""
        The Susurro icon shows whether dictation is ready: a waveform when \
        ready, an hourglass while a model loads, a down-arrow while one \
        downloads, and an exclamation mark if loading failed. The first \
        Parakeet load after install (and possibly after a macOS update) can take about 20 \
        seconds while macOS compiles the model. If you press the key before \
        it's ready, a notice tells you why nothing happened.
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
