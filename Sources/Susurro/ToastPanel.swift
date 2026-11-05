import AppKit

/// Transient toast in the overlay's corner: instant acknowledgment of a user
/// action (e.g. "downloading model…"). Auto-dismisses. Every toast carries the
/// app icon and a bold "Susurro" prefix so it is clear where it came from
/// (board, BEA-651). For events that complete
/// while the user's attention may be elsewhere, use a notification instead.
@MainActor
final class ToastPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private let icon: NSImageView
    private static let iconSize: CGFloat = 18
    private var dismissTask: Task<Void, Never>?

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .left

        icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon.image = NSImage(contentsOf: url)
        } else {
            icon.image = NSApp.applicationIconImage
        }

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
        background.addSubview(icon)
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ message: String, seconds: TimeInterval = 4) {
        let text = NSMutableAttributedString(string: "Susurro  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        text.append(NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]))
        label.attributedStringValue = text
        label.sizeToFit()

        let side: CGFloat = 16, gap: CGFloat = 8, iconSize = Self.iconSize
        let height = max(label.frame.height, iconSize) + 22
        let size = NSSize(width: side + iconSize + gap + label.frame.width + side + 4, height: height)
        panel.setContentSize(size)
        icon.frame = NSRect(x: side, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        label.frame.origin = NSPoint(x: side + iconSize + gap, y: (height - label.frame.height) / 2)

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
