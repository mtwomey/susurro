import Foundation

/// Recording modes, as chosen by the board on BEA-651 and BEA-678/BEA-691:
///
/// - Hold the push-to-talk key: recording starts, exactly as today.
///   Releasing it in the push-to-talk mode stops and inserts, as today.
/// - While still holding it, each tap of the mode key cycles
///   push-to-talk → hands-free → latch → push-to-talk… Taps are only
///   captured while the push-to-talk key is held.
/// - Hands-free: releasing the push-to-talk key keeps recording; text goes to
///   the app that was frontmost when hands-free began. Tap the push-to-talk
///   key to stop and insert, Esc to discard (Esc is captured only here).
///   Switching to another app stops the session.
/// - Latch: text stays tied to the pinned target while the user works
///   elsewhere. The machine only *requests* latch (`.requestLatch`); the app
///   answers `.latchRefused` when the target is not on the allowlist, and the
///   session carries on in hands-free. `.latchEnded` (target closed, a chunk
///   failed) also drops back to hands-free. App switches do not stop a latch.
///   Bare Esc is never captured in latch (the user is typing elsewhere):
///   stop happens on the push-to-talk *release*, so push-to-talk + Esc
///   discards instead.
/// - Auto-stop (board, BEA-651): a hands-free or latched session stops and
///   inserts after `idleLimit` seconds with no speech, or `safetyLimit`
///   seconds in total (two hours), each with a warning `warningLead` seconds
///   before.
///
/// Pure value type: no clocks, no AppKit. The caller feeds key events and
/// periodic ticks with timestamps (seconds, any monotonic base) and acts on
/// the returned effects.
public struct HandsFreeMachine: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Not recording.
        case idle
        /// Push-to-talk held, push-to-talk mode (today's behaviour).
        case holding(since: Double)
        /// Hands-free selected while the push-to-talk key is still down.
        case handsFreeHeld(since: Double, lastSpeech: Double)
        /// Hands-free: push-to-talk released, still recording.
        case handsFree(since: Double, lastSpeech: Double)
        /// Latch selected (or requested) while the push-to-talk key is down.
        case latchHeld(since: Double, lastSpeech: Double)
        /// Latched: push-to-talk released, text tied to the pinned target.
        case latched(since: Double, lastSpeech: Double)
        /// Latched and the push-to-talk key went down: its release stops and
        /// inserts; Esc before the release discards.
        case latchStopping(since: Double, lastSpeech: Double)
        /// A session just ended while the push-to-talk key was down; wait for
        /// its release so that release does nothing.
        case awaitingRelease
    }

    public enum Mode: Sendable, Equatable { case pushToTalk, handsFree, latch }

    public enum Event: Sendable, Equatable {
        case pttDown(at: Double)
        case pttUp(at: Double)
        /// The mode key (Command by default) was tapped.
        case modeTap(at: Double)
        case escape(at: Double)
        /// Speech was heard (from the pause segmenter); resets the idle timer.
        case heardSpeech(at: Double)
        /// Another app became frontmost.
        case appSwitched(at: Double)
        /// Periodic clock tick while recording (drives the safety stop).
        case tick(at: Double)
        /// The app could not pin a latch target (not on the allowlist,
        /// bridge unavailable). Recording continues in hands-free.
        case latchRefused
        /// The latch target went away or a chunk could not be delivered.
        /// Recording continues in hands-free.
        case latchEnded
    }

    public enum Effect: Sendable, Equatable {
        /// Start recording (show the hold-to-talk overlay).
        case startRecording
        /// Recording is now hands-free (switch to the hands-free indicator).
        case handsFree
        /// Try to pin a latch target; answer with `.latchRefused` if it fails.
        case requestLatch
        /// Back to push-to-talk while still held: drop any latch pin; the
        /// release will stop and insert.
        case pushToTalk
        /// Stop recording and insert what was said.
        case stopAndInsert(reason: StopReason)
        /// Stop recording and throw it away.
        case cancel
        /// An auto-stop is near; `remaining` seconds left.
        case warnAutoStop(reason: StopReason, remaining: Double)
    }

    public enum StopReason: Sendable, Equatable {
        /// Push-to-talk released (push-to-talk mode, today's path).
        case released
        /// Push-to-talk tapped while hands-free or latched.
        case tapped
        /// Total-length safety limit reached.
        case safetyLimit
        /// No speech for `idleLimit` seconds.
        case idle
        /// Another app became frontmost (hands-free only).
        case appSwitched
    }

    public struct Output: Sendable, Equatable {
        public var effects: [Effect]
        /// True when the key event should be swallowed (Esc while hands-free,
        /// or push-to-talk + Esc while latched).
        public var swallow: Bool
        public init(_ effects: [Effect] = [], swallow: Bool = false) {
            self.effects = effects
            self.swallow = swallow
        }
    }

    public private(set) var state: State = .idle
    public let safetyLimit: Double
    public let idleLimit: Double
    public let warningLead: Double
    private var warnedSafety = false
    private var warnedIdle = false

    public init(safetyLimit: Double = 7_200, idleLimit: Double = 60, warningLead: Double = 10) {
        self.safetyLimit = safetyLimit
        self.idleLimit = idleLimit
        self.warningLead = min(warningLead, safetyLimit, idleLimit)
    }

    public var isRecording: Bool {
        switch state {
        case .idle, .awaitingRelease: return false
        default: return true
        }
    }

    /// The current recording mode, nil when not recording.
    public var mode: Mode? {
        switch state {
        case .holding: return .pushToTalk
        case .handsFreeHeld, .handsFree: return .handsFree
        case .latchHeld, .latched, .latchStopping: return .latch
        case .idle, .awaitingRelease: return nil
        }
    }

    /// True once the session is chunked (hands-free or latch).
    public var isHandsFree: Bool { mode == .handsFree || mode == .latch }
    public var isLatched: Bool { mode == .latch }

    private var timing: (since: Double, last: Double)? {
        switch state {
        case .handsFreeHeld(let s, let l), .handsFree(let s, let l), .latchHeld(let s, let l),
             .latched(let s, let l), .latchStopping(let s, let l):
            return (s, l)
        default: return nil
        }
    }

    /// Same state, new last-speech time.
    private func with(lastSpeech t: Double) -> State {
        switch state {
        case .handsFreeHeld(let s, _): return .handsFreeHeld(since: s, lastSpeech: t)
        case .handsFree(let s, _): return .handsFree(since: s, lastSpeech: t)
        case .latchHeld(let s, _): return .latchHeld(since: s, lastSpeech: t)
        case .latched(let s, _): return .latched(since: s, lastSpeech: t)
        case .latchStopping(let s, _): return .latchStopping(since: s, lastSpeech: t)
        default: return state
        }
    }

    /// True while the push-to-talk key is physically down in a recording state.
    private var pttHeld: Bool {
        switch state {
        case .holding, .handsFreeHeld, .latchHeld, .latchStopping: return true
        default: return false
        }
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> Output {
        switch (state, event) {
        // Today's push-to-talk path.
        case (.idle, .pttDown(let t)):
            state = .holding(since: t)
            warnedSafety = false
            warnedIdle = false
            return Output([.startRecording])
        case (.holding, .pttUp):
            state = .idle
            return Output([.stopAndInsert(reason: .released)])

        // Mode key cycles while push-to-talk is held.
        case (.holding(let since), .modeTap(let t)):
            state = .handsFreeHeld(since: since, lastSpeech: t)
            return Output([.handsFree])
        case (.handsFreeHeld(let since, let last), .modeTap):
            state = .latchHeld(since: since, lastSpeech: last)
            return Output([.requestLatch])
        case (.latchHeld(let since, _), .modeTap):
            state = .holding(since: since)
            return Output([.pushToTalk])

        // Latch refused or ended: carry on in hands-free.
        case (.latchHeld(let since, let last), .latchRefused),
             (.latchHeld(let since, let last), .latchEnded):
            state = .handsFreeHeld(since: since, lastSpeech: last)
            return Output()
        case (.latched(let since, let last), .latchEnded):
            state = .handsFree(since: since, lastSpeech: last)
            return Output()

        // Releasing push-to-talk keeps a hands-free or latched session going.
        case (.handsFreeHeld(let since, let last), .pttUp):
            state = .handsFree(since: since, lastSpeech: last)
            return Output()
        case (.latchHeld(let since, let last), .pttUp):
            state = .latched(since: since, lastSpeech: last)
            return Output()

        // Speech keeps an idle session alive.
        case (_, .heardSpeech(let t)) where timing != nil:
            state = with(lastSpeech: t)
            warnedIdle = false
            return Output()

        // Switching apps ends a hands-free session (not a latched one).
        case (.handsFree, .appSwitched):
            state = .idle
            return Output([.stopAndInsert(reason: .appSwitched)])
        case (.handsFreeHeld, .appSwitched):
            state = .awaitingRelease
            return Output([.stopAndInsert(reason: .appSwitched)])

        // Stop hands-free: tap push-to-talk. Act on the press; ignore its release.
        case (.handsFree, .pttDown):
            state = .awaitingRelease
            return Output([.stopAndInsert(reason: .tapped)])
        case (.awaitingRelease, .pttUp):
            state = .idle
            return Output()

        // Stop latch: act on the release so push-to-talk + Esc can discard.
        case (.latched(let since, let last), .pttDown):
            state = .latchStopping(since: since, lastSpeech: last)
            return Output()
        case (.latchStopping, .pttUp):
            state = .idle
            return Output([.stopAndInsert(reason: .tapped)])

        // Discard. Esc is captured while hands-free, and in latch only
        // together with push-to-talk.
        case (.handsFree, .escape):
            state = .idle
            return Output([.cancel], swallow: true)
        case (.handsFreeHeld, .escape), (.latchHeld, .escape), (.latchStopping, .escape):
            state = .awaitingRelease
            return Output([.cancel], swallow: true)

        // Auto-stop (hands-free and latch; push-to-talk ends on release).
        case (_, .tick(let t)) where timing != nil:
            let (since, last) = timing!
            let total = t - since, quiet = t - last
            if total >= safetyLimit || quiet >= idleLimit {
                state = pttHeld ? .awaitingRelease : .idle
                return Output([.stopAndInsert(reason: total >= safetyLimit ? .safetyLimit : .idle)])
            }
            var effects: [Effect] = []
            if !warnedSafety && total >= safetyLimit - warningLead {
                warnedSafety = true
                effects.append(.warnAutoStop(reason: .safetyLimit, remaining: safetyLimit - total))
            }
            if !warnedIdle && quiet >= idleLimit - warningLead {
                warnedIdle = true
                effects.append(.warnAutoStop(reason: .idle, remaining: idleLimit - quiet))
            }
            return Output(effects)

        default:
            // Everything else (mode taps without push-to-talk held, bare Esc
            // in latch or push-to-talk, repeats, stray releases) passes
            // through untouched.
            return Output()
        }
    }

    /// Abort from outside (e.g. the recorder failed or the app is quitting).
    public mutating func reset() {
        state = .idle
        warnedSafety = false
        warnedIdle = false
    }
}

/// Which key latches hands-free. The board's concern (BEA-651): the latch key
/// must never be the push-to-talk key, and Right Command / Right Control are
/// both offered as push-to-talk keys. Resolution: use the preferred latch key
/// unless it is the push-to-talk key, otherwise the first other candidate.
public enum ModeKeyResolver {
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
