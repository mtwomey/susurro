import AppKit
import CoreGraphics
import SusurroCore

/// A selectable push-to-talk key: either a modifier (detected via flagsChanged)
/// or a regular key like F13 (detected via keyDown/keyUp and swallowed so the
/// focused app never sees it).
struct PTTKey: Sendable, Equatable {
    let id: String
    let title: String
    let keyCode: Int64
    let modifierFlag: CGEventFlags? // nil = regular key

    // Curated known-good hold keys. Regular keys (F13 etc.) are supported by the
    // monitor (modifierFlag: nil → keyDown/keyUp + swallow) but not offered in the
    // menu — a validated "Custom key…" capture flow is parked in docs/history/PLAN.md v2 for
    // programmable-keyboard users.
    static let all: [PTTKey] = [
        PTTKey(id: "rightOption",  title: "Right Option (⌥)",  keyCode: 61, modifierFlag: .maskAlternate),
        PTTKey(id: "rightCommand", title: "Right Command (⌘)", keyCode: 54, modifierFlag: .maskCommand),
        PTTKey(id: "rightControl", title: "Right Control (⌃)", keyCode: 62, modifierFlag: .maskControl),
    ]

    static let `default` = all[0] // Right Option

    static func saved() -> PTTKey {
        let id = Settings().pttKeyID
        return all.first { $0.id == id } ?? .default
    }

    func save() {
        Settings().pttKeyID = id
    }

    /// The hands-free latch key for a push-to-talk key (BEA-651): the saved
    /// preference unless it is the push-to-talk key, never the same key.
    static func latch(for ptt: PTTKey) -> PTTKey {
        let id = LatchKeyResolver.resolve(ptt: ptt.id,
                                          preferred: Settings().latchKeyID)
        return all.first { $0.id == id } ?? all.first { $0.id != ptt.id }!
    }

    static func saveLatch(_ key: PTTKey) {
        Settings().latchKeyID = key.id
    }
}

/// Watches for the configured push-to-talk key via a CGEventTap.
/// Requires Accessibility permission. Modifier events pass through untouched;
/// regular-key events for the PTT key are swallowed.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Hands-free (BEA-651): the latch key went down.
    var onLatch: (() -> Void)?
    /// Hands-free: Esc pressed. Return true to swallow it (only while latched).
    var onEscape: (() -> Bool)?

    /// The hands-free latch key; never the PTT key (see `PTTKey.latch(for:)`).
    var latchKey: PTTKey = PTTKey.latch(for: PTTKey.saved())
    private var latchIsDown = false
    private var escapeSwallowed = false
    private static let escapeKeyCode: Int64 = 53

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
        latchIsDown = false
        escapeSwallowed = false
    }

    /// Returns true if the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables taps that stall or when secure input engages — re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Hands-free latch key (a modifier other than the PTT key): report the
        // press, always pass it through.
        if type == .flagsChanged, keyCode == latchKey.keyCode, keyCode != key.keyCode,
           let flag = latchKey.modifierFlag {
            let down = event.flags.contains(flag)
            if down && !latchIsDown { latchIsDown = true; onLatch?() }
            else if !down { latchIsDown = false }
            return false
        }

        // Esc: only swallowed when the hands-free session claims it; the
        // matching keyUp is swallowed with it.
        if keyCode == Self.escapeKeyCode, key.keyCode != Self.escapeKeyCode {
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat { return escapeSwallowed }
                escapeSwallowed = onEscape?() ?? false
                return escapeSwallowed
            }
            if type == .keyUp {
                defer { escapeSwallowed = false }
                return escapeSwallowed
            }
        }

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
