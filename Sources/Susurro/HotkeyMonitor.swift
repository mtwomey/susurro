import AppKit
import CoreGraphics

/// Watches for the push-to-talk key (Right Option) via a CGEventTap.
/// Requires Accessibility permission. Events pass through untouched.
@MainActor
final class HotkeyMonitor {
    static let rightOptionKeyCode: Int64 = 61

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    /// Check (and optionally prompt for) Accessibility permission.
    static func ensureAccessibility(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt is a C global var — not concurrency-safe under
        // Swift 6 strict checking. Its value is the stable literal below.
        return AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        )
    }

    /// Returns false if the tap could not be created (permission missing).
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated {
                        monitor.handle(type: type, event: event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall or when secure input engages — re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOptionKeyCode
        else { return }

        let down = event.flags.contains(.maskAlternate)
        if down && !isDown {
            isDown = true
            onPress?()
        } else if !down && isDown {
            isDown = false
            onRelease?()
        }
    }
}
