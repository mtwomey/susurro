import AppKit
import CoreGraphics

/// A selectable push-to-talk key: either a modifier (detected via flagsChanged)
/// or a regular key like F13 (detected via keyDown/keyUp and swallowed so the
/// focused app never sees it).
struct PTTKey: Sendable, Equatable {
    let id: String
    let title: String
    let keyCode: Int64
    let modifierFlag: CGEventFlags? // nil = regular key

    static let all: [PTTKey] = [
        PTTKey(id: "rightOption",  title: "Right Option (⌥)",  keyCode: 61,  modifierFlag: .maskAlternate),
        PTTKey(id: "rightCommand", title: "Right Command (⌘)", keyCode: 54,  modifierFlag: .maskCommand),
        PTTKey(id: "rightControl", title: "Right Control (⌃)", keyCode: 62,  modifierFlag: .maskControl),
        PTTKey(id: "f13",          title: "F13",               keyCode: 105, modifierFlag: nil),
        PTTKey(id: "f14",          title: "F14",               keyCode: 107, modifierFlag: nil),
        PTTKey(id: "f15",          title: "F15",               keyCode: 113, modifierFlag: nil),
    ]

    static let `default` = all[0] // Right Option

    static func saved() -> PTTKey {
        let id = UserDefaults.standard.string(forKey: "pttKeyID")
        return all.first { $0.id == id } ?? .default
    }

    func save() {
        UserDefaults.standard.set(id, forKey: "pttKeyID")
    }
}

/// Watches for the configured push-to-talk key via a CGEventTap.
/// Requires Accessibility permission. Modifier events pass through untouched;
/// regular-key events for the PTT key are swallowed.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// The active PTT key. Changeable at runtime; the tap listens for all
    /// relevant event types and filters here.
    var key: PTTKey = PTTKey.saved()

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

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let swallow = MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
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

    /// Returns true if the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables taps that stall or when secure input engages — re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if let flag = key.modifierFlag {
            // Modifier PTT key: watch flagsChanged, always pass through
            guard type == .flagsChanged, keyCode == key.keyCode else { return false }
            let down = event.flags.contains(flag)
            transition(down: down)
            return false
        } else {
            // Regular PTT key (e.g. F13): watch keyDown/keyUp, swallow our key
            guard keyCode == key.keyCode else { return false }
            switch type {
            case .keyDown:
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat { transition(down: true) }
                return true
            case .keyUp:
                transition(down: false)
                return true
            default:
                return false
            }
        }
    }

    private func transition(down: Bool) {
        if down && !isDown {
            isDown = true
            onPress?()
        } else if !down && isDown {
            isDown = false
            onRelease?()
        }
    }
}
