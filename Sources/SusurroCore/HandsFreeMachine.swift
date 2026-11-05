import Foundation

/// Hands-free (latched) dictation, as chosen by the board on BEA-651:
///
/// - Hold the push-to-talk key: recording starts, exactly as today.
/// - Release it: stop and insert, exactly as today.
/// - While still holding it, tap the latch key: the recording latches.
///   Releasing the push-to-talk key then keeps recording.
/// - While latched: tap the push-to-talk key to stop and insert, or press
///   Esc to discard. Esc is only captured while latched.
/// - A safety stop ends a latched session after `safetyLimit` seconds, with a
///   warning `warningLead` seconds before.
///
/// Pure value type: no clocks, no AppKit. The caller feeds key events and
/// periodic ticks with timestamps (seconds, any monotonic base) and acts on
/// the returned effects.
public struct HandsFreeMachine: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Not recording.
        case idle
        /// Push-to-talk held, not latched (today's behaviour).
        case holding(since: Double)
        /// Latched while the push-to-talk key is still physically down.
        case latchedHeld(since: Double)
        /// Latched, hands-free: push-to-talk released, still recording.
        case latched(since: Double)
        /// A session just ended while the push-to-talk key was down; wait for
        /// its release so that release does nothing.
        case awaitingRelease
    }

    public enum Event: Sendable, Equatable {
        case pttDown(at: Double)
        case pttUp(at: Double)
        case latchDown(at: Double)
        case escape(at: Double)
        /// Periodic clock tick while recording (drives the safety stop).
        case tick(at: Double)
    }

    public enum Effect: Sendable, Equatable {
        /// Start recording (show the hold-to-talk overlay).
        case startRecording
        /// Recording is now hands-free (switch to the hands-free indicator).
        case latched
        /// Stop recording and insert what was said.
        case stopAndInsert(reason: StopReason)
        /// Stop recording and throw it away.
        case cancel
        /// The safety stop is near; `remaining` seconds left.
        case warnSafetyStop(remaining: Double)
    }

    public enum StopReason: Sendable, Equatable {
        /// Push-to-talk released (hold mode, today's path).
        case released
        /// Push-to-talk tapped while latched.
        case tapped
        /// Safety limit reached.
        case safetyLimit
    }

    public struct Output: Sendable, Equatable {
        public var effects: [Effect]
        /// True when the key event should be swallowed (only Esc while latched).
        public var swallow: Bool
        public init(_ effects: [Effect] = [], swallow: Bool = false) {
            self.effects = effects
            self.swallow = swallow
        }
    }

    public private(set) var state: State = .idle
    public let safetyLimit: Double
    public let warningLead: Double
    private var warned = false

    public init(safetyLimit: Double = 600, warningLead: Double = 30) {
        self.safetyLimit = safetyLimit
        self.warningLead = min(warningLead, safetyLimit)
    }

    public var isRecording: Bool {
        switch state {
        case .holding, .latchedHeld, .latched: return true
        case .idle, .awaitingRelease: return false
        }
    }

    public var isHandsFree: Bool {
        switch state {
        case .latchedHeld, .latched: return true
        default: return false
        }
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> Output {
        switch (state, event) {
        // Today's push-to-talk path.
        case (.idle, .pttDown(let t)):
            state = .holding(since: t)
            warned = false
            return Output([.startRecording])
        case (.holding, .pttUp):
            state = .idle
            return Output([.stopAndInsert(reason: .released)])

        // Latch while holding.
        case (.holding(let since), .latchDown):
            state = .latchedHeld(since: since)
            return Output([.latched])
        case (.latchedHeld(let since), .pttUp):
            state = .latched(since: since)
            return Output()

        // Stop: tap push-to-talk. Act on the press; ignore its release.
        case (.latched, .pttDown):
            state = .awaitingRelease
            return Output([.stopAndInsert(reason: .tapped)])
        case (.awaitingRelease, .pttUp):
            state = .idle
            return Output()

        // Discard: Esc, captured only while hands-free.
        case (.latched, .escape):
            state = .idle
            return Output([.cancel], swallow: true)
        case (.latchedHeld, .escape):
            state = .awaitingRelease
            return Output([.cancel], swallow: true)

        // Safety stop (hands-free only; hold mode ends when the key is released).
        case (.latched(let since), .tick(let t)), (.latchedHeld(let since), .tick(let t)):
            let elapsed = t - since
            if elapsed >= safetyLimit {
                let held: Bool
                if case .latchedHeld = state { held = true } else { held = false }
                state = held ? .awaitingRelease : .idle
                return Output([.stopAndInsert(reason: .safetyLimit)])
            }
            if !warned && elapsed >= safetyLimit - warningLead {
                warned = true
                return Output([.warnSafetyStop(remaining: safetyLimit - elapsed)])
            }
            return Output()

        default:
            // Everything else (latch key or Esc when not hands-free, repeats,
            // stray releases) passes through untouched.
            return Output()
        }
    }

    /// Abort from outside (e.g. the recorder failed or the app is quitting).
    public mutating func reset() {
        state = .idle
        warned = false
    }
}

/// Which key latches hands-free. The board's concern (BEA-651): the latch key
/// must never be the push-to-talk key, and Right Command / Right Control are
/// both offered as push-to-talk keys. Resolution: use the preferred latch key
/// unless it is the push-to-talk key, otherwise the first other candidate.
public enum LatchKeyResolver {
    /// Candidate ids, in fallback order. Matches `PTTKey.all` ids in the app.
    public static let candidates = ["rightCommand", "rightOption", "rightControl"]
    public static let defaultPreferred = "rightCommand"

    public static func resolve(ptt: String, preferred: String?) -> String {
        if let preferred, preferred != ptt, candidates.contains(preferred) {
            return preferred
        }
        if defaultPreferred != ptt { return defaultPreferred }
        return candidates.first { $0 != ptt } ?? defaultPreferred
    }

    /// Choices to offer in the menu for a given push-to-talk key.
    public static func choices(ptt: String) -> [String] {
        candidates.filter { $0 != ptt }
    }
}
