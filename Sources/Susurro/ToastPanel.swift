import AppKit

/// Transient toast in the overlay's corner: instant acknowledgment of a user
/// action (e.g. "downloading model…"). Auto-dismisses. For events that complete
/// while the user's attention may be elsewhere, use a notification instead.
@MainActor
final class ToastPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private var dismissTask: Task<Void, Never>?

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let background = ToastBackgroundView()
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ message: String, seconds: TimeInterval = 4) {
        label.stringValue = message
        label.sizeToFit()

        let padding = NSSize(width: 40, height: 22)
        let size = NSSize(width: label.frame.width + padding.width,
                          height: label.frame.height + padding.height)
        panel.setContentSize(size)
        label.frame.origin = NSPoint(
            x: (size.width - label.frame.width) / 2,
            y: (size.height - label.frame.height) / 2
        )

        if let screen = NSScreen.main {
            let margin: CGFloat = 16
            let frame = screen.visibleFrame
            // Top-right, just under the menu bar: spatially connected to the
            // menu action that triggered it, and in the same neighborhood where
            // the completion notification will later appear.
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - size.width - margin,
                y: frame.maxY - size.height - margin
            ))
        }

        panel.orderFrontRegardless()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}

private final class ToastBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
    }
}
