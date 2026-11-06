import Foundation
import os

// MARK: - R7 (F14): unified logging

/// Susurro's `os.Logger`s (R7, BEA-683). Subsystem = the app's bundle id
/// (`com.mtwomey.susurro`; the CLI and tests fall back to the same string),
/// so `log stream --predicate 'subsystem == "com.mtwomey.susurro"'` shows
/// everything. Categories:
/// - `dictation`: PTT/dev-feed lifecycle and the per-dictation record
/// - `engine`: model load/download, transcription failures, AI cleanup
/// - `handsfree`: hands-free session, chunks and joins
/// - `textHandling`: pre-insert stage, rules, insertion notes
///
/// Privacy: field text and transcripts are never logged at default level.
/// `event(_:)` marks its message public, so only pass strings that carry
/// no user text (counts, decisions, errors, ids). The transcript goes
/// through `Log.transcript` only: debug level, `privacy: .private`.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.mtwomey.susurro"
    public static let dictation = Logger(subsystem: subsystem, category: "dictation")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let handsfree = Logger(subsystem: subsystem, category: "handsfree")
    public static let textHandling = Logger(subsystem: subsystem, category: "textHandling")

    /// Debug-only, private transcript trace (redacted unless private data
    /// logging is enabled on the machine).
    public static func transcript(raw: String, cleaned: String) {
        dictation.debug("transcript: \(raw, privacy: .private) -> \(cleaned, privacy: .private)")
    }
}

extension Logger {
    /// A diagnostic line with no user text in it (shown unredacted).
    public func event(_ message: String) {
        notice("\(message, privacy: .public)")
    }
    /// A failure with no user text in it (shown unredacted).
    public func failure(_ message: String) {
        error("\(message, privacy: .public)")
    }
}

// MARK: - The per-dictation record

/// One structured record per dictation (R7): what triggered it, which
/// engine ran, per-stage timings, where the insert context came from and
/// how it ended. Built only from enums, counts, ids and durations — there
/// is no field for transcript or field text, so the record cannot leak it.
/// Emitted to `Log.dictation` and appended to text-handling.log.
public struct DictationRecord: Sendable, Equatable {
    public enum Trigger: String, Sendable { case pushToTalk = "ptt", handsFree = "handsfree", devFeed = "devfeed" }
    public enum Outcome: String, Sendable {
        /// Text typed (or copied when typing was blocked) into the field.
        case inserted
        /// The pipeline produced nothing to insert (silence, filtered).
        case empty
        /// Text-handling left nothing to type (e.g. only a retraction).
        case nothingToType
        /// The insert plan declined to insert.
        case notInserted
        /// Hands-free chunk finished after an app switch -> clipboard.
        case clipboardAppSwitch
        /// Hands-free session cancelled while the chunk was transcribing.
        case dropped
    }

    public var trigger: Trigger
    public var engine: EngineKind
    public var timings: StageTimings
    public var source: ContextSource?
    public var provider: String?
    /// Bundle id of the target app (an id, not user text).
    public var app: String?
    /// FieldSnapshot.detail: AX read path with lengths/positions only.
    public var ax: String?
    public var sameApp: Bool?
    /// CrossDictationJoin.logLine fields (numbers and decision only).
    public var cross: String?
    public var transcriptionFailed: Bool
    public var outcome: Outcome

    public init(trigger: Trigger, engine: EngineKind, timings: StageTimings = StageTimings(),
                source: ContextSource? = nil, provider: String? = nil, app: String? = nil,
                ax: String? = nil, sameApp: Bool? = nil, cross: String? = nil,
                transcriptionFailed: Bool = false, outcome: Outcome) {
        self.trigger = trigger
        self.engine = engine
        self.timings = timings
        self.source = source
        self.provider = provider
        self.app = app
        self.ax = ax
        self.sameApp = sameApp
        self.cross = cross
        self.transcriptionFailed = transcriptionFailed
        self.outcome = outcome
    }

    /// Space-separated key=value line, `-` for "not known". The context
    /// fields (source…sameApp, then the cross-join fields) keep the order of
    /// the pre-R7 text-handling.log lines, so existing greps still match.
    public var line: String {
        func v(_ s: String?) -> String { s.map { $0.isEmpty ? "-" : $0 } ?? "-" }
        var parts = [
            "trigger=\(trigger.rawValue)",
            "engine=\(engine.rawValue)",
            "outcome=\(outcome.rawValue)",
            "source=\(v(source?.rawValue))",
            "provider=\(v(provider))",
            "app=\(v(app))",
            "ax=\(v(ax))",
            "sameApp=\(sameApp.map(String.init) ?? "-")",
        ]
        if let cross, !cross.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(cross.trimmingCharacters(in: .whitespaces))
        }
        if transcriptionFailed { parts.append("transcribeFailed=true") }
        parts.append(timings.logFields)
        return parts.joined(separator: " ")
    }

    /// Writes the record to the unified log (public: it carries no text).
    public func emit() {
        Log.dictation.notice("record \(line, privacy: .public)")
    }
}
