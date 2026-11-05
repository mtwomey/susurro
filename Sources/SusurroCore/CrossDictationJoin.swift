import Foundation

/// Cross-dictation joins (BEA-677): separate dictations (hold-to-talk, or
/// separate hands-free sessions) are each transcribed on their own, so the
/// engine closes every one with a full stop when the user pauses. When the
/// next dictation lands right after Susurro's previous text, unchanged and
/// soon, the join is decided with the HandsFreeJoin joint-clip method and, on
/// continuation, only Susurro's own trailing "." is removed (one Backspace).
///
/// This type is the pure eligibility guard: it never removes anything unless
/// every check proves the previous dictation's mark is still the last thing
/// before the cursor, untouched.
public enum CrossDictationJoin {
    /// Default maximum gap between the end of the previous dictation's
    /// typing and the start of the new dictation's recording.
    public static let defaultMaxGap: TimeInterval = 12

    /// What Susurro typed last time, recorded right after typing it.
    public struct Previous: Sendable, Equatable {
        /// The full text typed (including its leading space and final mark).
        public var typed: String
        public var pid: pid_t
        /// Identity of the focused field (e.g. AX element hash / role path);
        /// nil when unknown.
        public var fieldID: String?
        /// When typing finished.
        public var endedAt: Date
        /// Where the insertion ended inside the field value, when readable.
        public var position: ValuePosition?
        public init(typed: String, pid: pid_t, fieldID: String?, endedAt: Date, position: ValuePosition? = nil) {
            self.typed = typed; self.pid = pid; self.fieldID = fieldID
            self.endedAt = endedAt; self.position = position
        }
    }

    /// The field as seen when the new dictation starts.
    public struct Current: Sendable, Equatable {
        public var pid: pid_t
        public var fieldID: String?
        public var startedAt: Date
        /// Text before the cursor (Accessibility or anchored value); nil when
        /// unreadable.
        public var before: String?
        /// Text after the cursor; nil when unknown.
        public var after: String?
        /// Caret offset / value length, when readable.
        public var position: ValuePosition?
        /// Keystrokes typed by the user since Susurro's previous insertion
        /// (from the hotkey monitor's key tap); nil when not observed.
        public var userKeystrokesSince: Int?
        public init(pid: pid_t, fieldID: String?, startedAt: Date, before: String?,
                    after: String? = nil, position: ValuePosition? = nil, userKeystrokesSince: Int? = nil) {
            self.pid = pid; self.fieldID = fieldID; self.startedAt = startedAt
            self.before = before; self.after = after; self.position = position
            self.userKeystrokesSince = userKeystrokesSince
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Eligible: decide with the joint clip; `mark` is Susurro's own
        /// trailing mark that may be removed on continuation.
        case eligible(mark: Character, previousBody: String)
        case ineligible(Reason)
    }

    public enum Reason: String, Sendable {
        case noPrevious = "no_prev"
        case differentApp = "other_app"
        case differentField = "other_field"
        case gapTooLong = "gap"
        case noPeriod = "no_period"      // ? ! or no mark: always kept
        case unreadable = "unreadable"   // cannot prove the mark is untouched
        case edited = "edited"           // text before the cursor differs
        case textAfterCursor = "after"   // cursor not at the end of our text
        case typedSince = "typed"        // user keystrokes since our insertion
        case positionMoved = "moved"     // caret/length differ from recorded
    }

    public static func check(previous: Previous?, current: Current,
                             maxGap: TimeInterval = defaultMaxGap) -> Verdict {
        guard let previous else { return .ineligible(.noPrevious) }
        guard previous.pid == current.pid else { return .ineligible(.differentApp) }
        if let a = previous.fieldID, let b = current.fieldID, a != b { return .ineligible(.differentField) }
        let gap = current.startedAt.timeIntervalSince(previous.endedAt)
        guard gap >= 0, gap <= maxGap else { return .ineligible(.gapTooLong) }
        // Only a single trailing "." is ever retracted: "?" and "!" are real
        // intent, "..." is deliberate.
        let (body, mark) = HandsFreeJoin.holdMark(previous.typed)
        guard mark == ".", previous.typed.last == "." else { return .ineligible(.noPeriod) }
        if let typed = current.userKeystrokesSince, typed > 0 { return .ineligible(.typedSince) }
        // Proof the mark is untouched requires reading the text before the
        // cursor: it must end with exactly what Susurro typed.
        guard let before = current.before else { return .ineligible(.unreadable) }
        let typedCore = previous.typed.trimmingCharacters(in: .whitespaces)
        guard !typedCore.isEmpty, before.hasSuffix(typedCore) else { return .ineligible(.edited) }
        if let after = current.after, after.contains(where: { !$0.isWhitespace }) {
            return .ineligible(.textAfterCursor)
        }
        if let p = previous.position, let c = current.position, p != c { return .ineligible(.positionMoved) }
        return .eligible(mark: ".", previousBody: HeldMarkJoiner.lastWords(body))
    }

    /// The edit to apply for the new dictation `next` (already text-handled
    /// as a sentence start) once the joint clip decided the join.
    /// Continuation: delete Susurro's "." (1 Backspace) and type " " + `next`
    /// with its first word lower-cased. Otherwise: no change to `next`.
    public static func edit(decision: HandsFreeJoin.Decision, next: String) -> (deleteBackward: Int, text: String) {
        switch decision {
        case .continuation:
            return HandsFreeJoin.joinedAfterShown(decision: .continuation, next: next)
        case .sentenceBreak, .unmatched:
            return (0, next)
        }
    }

    /// One text-handling.log line: numbers and decision only, no text.
    public static func logLine(verdict: Verdict, gap: TimeInterval?, decision: HandsFreeJoin.Decision?) -> String {
        let g = gap.map { String(format: "%.1f", $0) } ?? "-"
        switch verdict {
        case .ineligible(let r): return "xjoin=skip reason=\(r.rawValue) gap=\(g)"
        case .eligible:
            let d: String
            switch decision {
            case .continuation?: d = "continue"
            case .sentenceBreak?: d = "break"
            case .unmatched?: d = "unmatched"
            case nil: d = "pending"
            }
            return "xjoin=\(d) gap=\(g)"
        }
    }
}
