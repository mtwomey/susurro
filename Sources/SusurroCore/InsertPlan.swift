import Foundation

/// What to do with one finished dictation (BEA-664, review R2): the pure
/// decision half of the app's insert step. The app gathers the facts
/// (frontmost app, resolved field context, secure input, joiner state) on the
/// main actor, asks `InsertPlan.make`, and carries out the plan (Backspace,
/// typing, clipboard, memory). No AppKit, no Accessibility, no side effects.
public struct InsertPlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// A hands-free chunk finished after an app switch: copy `text` to the
        /// clipboard, drop the held mark and the memory tail, type nothing.
        case clipboardAfterAppSwitch(text: String)
        /// Type `text` after `deleteBackward` Backspaces (both may be empty/0).
        case insert(text: String, deleteBackward: Int)
    }

    public var action: Action
    /// The piece's own end mark was appended to `text`; tell the joiner it is
    /// shown once typing succeeded.
    public var markShown = false
    /// Cross-dictation log fields (" xjoin=..."), empty when not evaluated.
    public var crossLog = ""
    /// Diagnostic notes for the app log (never field text).
    public var notes: [String] = []

    /// The dictation's join state, as produced by the pipeline.
    public struct Join: Sendable {
        /// Text to type in place for a decided hands-free join (held mark or
        /// not + this chunk); nil = no hands-free join this chunk.
        public var joinedText: String?
        /// The previous chunk's typed body (the held mark's owner).
        public var previousBody: String?
        public var previousShown = false
        public var previousMark: Character = "."
        public var decision: HandsFreeJoin.Decision = .unmatched
        public init(joinedText: String? = nil, previousBody: String? = nil, previousShown: Bool = false,
                    previousMark: Character = ".", decision: HandsFreeJoin.Decision = .unmatched) {
            self.joinedText = joinedText
            self.previousBody = previousBody
            self.previousShown = previousShown
            self.previousMark = previousMark
            self.decision = decision
        }
    }

    /// Hands-free chunk after an app switch: the text to copy. A held mark
    /// travels with the copied words; a mark already shown in the old field
    /// stays there.
    public static func appSwitchClipboardText(processed: String, join: Join) -> String {
        join.previousShown ? processed
            : (join.joinedText.map { $0.trimmingCharacters(in: .whitespaces) } ?? processed)
    }

    /// Plan the insertion of `processed` (the dictation's cleaned text, before
    /// the text stage).
    /// - Parameters:
    ///   - expectedPID: hands-free only — the app the session dictates into.
    ///   - heldMark: the joiner's currently held mark (this piece's own).
    ///   - cross: the previous dictation record + the joint-clip decision, for
    ///     push-to-talk cross-dictation joins (nil = none).
    ///   - fieldValue: the AX-read value, for cursorless-value positions.
    public static func make(processed: String, join: Join, isHandsFree: Bool,
                            expectedPID: Int32?, frontmostPID: Int32?,
                            context: InsertContext, stage: TextHandlingStage, secureInput: Bool,
                            heldMark: Character?,
                            cross: (previous: CrossDictationJoin.Previous, decision: HandsFreeJoin.Decision?)?,
                            startedAt: Date, fieldValue: String?) -> InsertPlan {
        if let expectedPID, frontmostPID != expectedPID {
            return InsertPlan(action: .clipboardAfterAppSwitch(
                text: appSwitchClipboardText(processed: processed, join: join)))
        }
        var plan = InsertPlan(action: .insert(text: "", deleteBackward: 0))
        var text = stage.apply(processed, context)
        var deleteCount = 0
        // Shown-mark mode (BEA-657 follow-up): marks are typed at the pause
        // and retracted with one guarded Backspace only when the field is
        // readable and the mark sits right before the cursor.
        let readableField = [.accessibility, .anchoredValue, .appBridge].contains(context.source)
            && context.before != nil && !secureInput
        if join.previousShown, join.joinedText != nil, let joinAfter = join.previousBody {
            if readableField, HandsFreeJoin.canRetract(before: context.before, mark: join.previousMark,
                                                       previousBody: joinAfter) {
                let edit = HandsFreeJoin.joinedAfterShown(decision: join.decision, next: processed)
                deleteCount = edit.deleteBackward
                text = edit.text
            } else {
                // Cursor moved / unreadable: the shown mark stays; the piece
                // goes in as a fresh dictation (pre-BEA-657 result).
                plan.notes.append("handsfree: shown mark not in place, join skipped")
            }
        } else if let joinText = join.joinedText, let joinAfter = join.previousBody {
            // Type the join in place only if the cursor is still right after
            // the previous chunk's words. Unknown context counts as in place
            // (the session's own typing is the only thing that ran since).
            // Moved cursor: B goes in fresh and A's held mark is dropped.
            if HandsFreeJoin.isInPlace(before: context.before, previousBody: joinAfter) {
                text = joinText
            } else {
                plan.notes.append("handsfree: cursor moved, join skipped")
            }
        }
        if !isHandsFree, join.joinedText == nil, let frontmostPID, let cross {
            var position: ValuePosition?
            if context.source == .anchoredValue, let before = context.before, let value = fieldValue {
                position = ValuePosition(caretOffset: (before as NSString).length,
                                         valueLength: (value as NSString).length)
            }
            let current = CrossDictationJoin.Current(pid: frontmostPID, fieldID: nil, startedAt: startedAt,
                                                     before: readableField ? context.before : nil,
                                                     after: context.after, position: position)
            let verdict = CrossDictationJoin.check(previous: cross.previous, current: current)
            if case .eligible = verdict, let decision = cross.decision, !text.isEmpty {
                let edit = CrossDictationJoin.edit(decision: decision, next: text)
                deleteCount = edit.deleteBackward
                text = edit.text
            }
            plan.crossLog = " " + CrossDictationJoin.logLine(verdict: verdict,
                                                             gap: startedAt.timeIntervalSince(cross.previous.endedAt),
                                                             decision: cross.decision)
        }
        // Show this piece's own end mark now if the field is readable;
        // otherwise it stays held (typed at the next join or at stop).
        if isHandsFree, readableField, let heldMark, !text.isEmpty {
            text.append(heldMark)
            plan.markShown = true
        }
        plan.action = .insert(text: text, deleteBackward: deleteCount)
        return plan
    }
}

extension InsertPlan.Join {
    /// The join state a hands-free step leaves for the insert decision
    /// (nil / fresh / unresolved = no join).
    public init(_ step: DictationPipeline.HandsFreeStep?) {
        self.init()
        if case .joined(let held, let decision, _, let joined)? = step {
            joinedText = joined
            previousBody = held.body
            previousShown = held.shown
            previousMark = held.mark
            self.decision = decision
        }
    }
}

extension DictationPipeline.HandsFreeStep {
    /// The chunk's own text to insert: the fresh text, the next chunk's words
    /// after a join, or `cleaned` when nothing was decided.
    public func pieceText(cleaned: String) -> String {
        switch self {
        case .fresh(let text): return text
        case .joined(_, _, let next, _): return next
        case .unresolved: return cleaned
        }
    }
}
