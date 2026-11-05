import AppKit

/// Recording overlay: a small floating pill (red dot + live waveform + timer)
/// in the bottom-right corner. Built on a non-activating borderless NSPanel so it
/// can never steal focus from the app being dictated into — which is what made
/// the old tkinter overlay require the save/restore-focus dance this app deleted.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let waveform: WaveformView

    init() {
        let size = NSSize(width: 220, height: 48)
        waveform = WaveformView(frame: NSRect(origin: .zero, size: size))

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        panel.contentView = waveform
    }

    func show() {
        position()
        waveform.begin()
        panel.orderFrontRegardless()
    }

    func hide() {
        waveform.end()
        waveform.handsFree = false
        waveform.warning = false
        panel.orderOut(nil)
    }

    /// Hands-free (BEA-651): blue outline, steady blue dot and a HANDS-FREE
    /// caption, so a latched session never looks like hold-to-talk.
    func setHandsFree(_ on: Bool) {
        waveform.handsFree = on
        waveform.needsDisplay = true
    }

    /// An auto-stop is near: the outline turns orange until speech resumes.
    func setWarning(_ on: Bool) {
        waveform.warning = on
        waveform.needsDisplay = true
    }

    /// Feed a level sample (0...1). Safe to call from any thread via main-hop upstream.
    func push(level: Float) {
        waveform.push(level: level)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 24
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - margin,
            y: frame.minY + margin
        ))
    }
}

/// Draws the pill: dark rounded background, red record dot, scrolling level bars,
/// and elapsed time. Redraws on a 30 Hz timer while visible.
final class WaveformView: NSView {
    private var levels: [Float] = []
    private let maxBars = 42
    private var startedAt: Date?
    private var redrawTimer: Timer?
    var handsFree = false
    var warning = false

    func begin() {
        levels.removeAll()
        startedAt = Date()
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    func end() {
        redrawTimer?.invalidate()
        redrawTimer = nil
        startedAt = nil
    }

    func push(level: Float) {
        // Speech peaks on typical mics run ~0.05–0.3; perceptual-ish scaling
        let scaled = min(1, pow(level / 0.25, 0.6))
        levels.append(scaled)
        if levels.count > maxBars {
            levels.removeFirst(levels.count - maxBars)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Background pill
        let bg = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.78).setFill()
        bg.fill()
        if handsFree {
            let accent: NSColor = warning ? .systemOrange : .systemBlue
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                                    xRadius: bounds.height / 2 - 1.5, yRadius: bounds.height / 2 - 1.5)
            ring.lineWidth = 3
            accent.setStroke()
            ring.stroke()
            let caption = NSAttributedString(string: "HANDS-FREE", attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: accent,
                .kern: 1.0,
            ])
            let size = caption.size()
            caption.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 4))
        }

        let midY = bounds.midY

        // Pulsing red record dot
        let dotDiameter: CGFloat = 10
        let pulse = 0.65 + 0.35 * abs(sin(Date().timeIntervalSinceReferenceDate * 2.2))
        // Hold-to-talk: pulsing red. Hands-free: steady blue (latched).
        (handsFree ? NSColor.systemBlue : NSColor.systemRed.withAlphaComponent(pulse)).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: 16, y: midY - dotDiameter / 2, width: dotDiameter, height: dotDiameter
        )).fill()

        // Waveform bars
        let barsLeft: CGFloat = 36
        let barsRight: CGFloat = bounds.width - 58
        let barAreaWidth = barsRight - barsLeft
        let step = barAreaWidth / CGFloat(maxBars)
        let barWidth = max(step - 1.5, 1)
        let maxBarHeight: CGFloat = bounds.height - 20

        NSColor.white.withAlphaComponent(0.9).setFill()
        for (index, level) in levels.enumerated() {
            let height = max(2, CGFloat(level) * maxBarHeight)
            let x = barsLeft + CGFloat(index) * step
            NSBezierPath(roundedRect: NSRect(
                x: x, y: midY - height / 2, width: barWidth, height: height
            ), xRadius: 1, yRadius: 1).fill()
        }

        // Elapsed time
        if let startedAt {
            let elapsed = Int(-startedAt.timeIntervalSinceNow)
            let text = elapsed >= 3_600
                ? String(format: "%d:%02d:%02d", elapsed / 3_600, elapsed / 60 % 60, elapsed % 60)
                : String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            string.draw(at: NSPoint(
                x: bounds.width - textSize.width - 16,
                y: midY - textSize.height / 2
            ))
        }
    }
}
