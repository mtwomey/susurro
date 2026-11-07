import Foundation

// Passive AX learning of latch capability (BEA-694; docs/BRIDGES.md
// "Passive learning"; LATCH_FEASIBILITY.md "Local qualification" and the
// "Passive-learning spike").
//
// Idea: during ordinary FRONTMOST dictation in an unlisted app, try each chunk
// as an AX `kAXSelectedText` write, read the field back, and type the chunk
// the normal way only if the write provably inserted nothing. The outcome of
// each attempt (never its text) is recorded per (bundle ID, field role, app
// version). Enough clean successes, and no no-op or partial ever, make the
// app/field kind a latch *candidate* with no user action.
//
// Core only and OFF by default (`LatchPassiveLearning.enabledByDefault`):
// wiring it into the insertion path changes how text reaches every unlisted
// app, and that needs a frontmost live run on Slack / Hermes / Zen, which
// takes the user's focus (open decision, BEA-694). A candidate never engages
// latch on its own (`admitsLatch == false`): frontmost observation cannot see
// the two background criteria (identity after focus loss, background
// delivery), so it is at most a pointer to the guided self-test (BEA-693).

/// What one frontmost AX write did, judged only from the read-back.
public enum AXWriteOutcome: String, Codable, Sendable, Equatable {
    /// The field equals the old value with exactly the chunk spliced in at
    /// the caret, and the caret sits after it.
    case all
    /// Value and caret are unchanged: a silent no-op (VS Code, Obsidian in
    /// the spike). Safe to type the chunk the normal way.
    case none
    /// Anything else, including an unreadable read-back. Not provably ours
    /// and not provably absent: never type over it, never delete it.
    case partial
}

/// Snapshot of a field for the classifier (UTF-16 caret offset).
public struct AXFieldSnapshot: Sendable, Equatable {
    public var value: String
    public var caret: Int
    public init(value: String, caret: Int) {
        self.value = value
        self.caret = caret
    }
}

public enum LatchPassiveLearning {
    /// Behind a setting, off, until the frontmost live run passes.
    public static let enabledByDefault = false

    /// Consecutive clean AX inserts before a field kind becomes a candidate.
    public static let candidateThreshold = 5

    /// Whether a local candidate may engage latch. Always false: passive
    /// observation is frontmost, so identity and background delivery are
    /// unproven. Full support or nothing.
    public static let admitsLatch = false

    /// Only attempt the AX write when the field says it can work. Settable is
    /// NOT a predictor (VS Code / Obsidian report settable and no-op), so this
    /// only filters; the read-back decides.
    public static func shouldAttempt(selectedTextSettable: Bool, contextReadable: Bool,
                                     secureField: Bool, secureInput: Bool) -> Bool {
        selectedTextSettable && contextReadable && !secureField && !secureInput
    }

    /// Classify an attempt from the before/after read-backs.
    public static func classify(before: AXFieldSnapshot, chunk: String,
                                after: AXFieldSnapshot?) -> AXWriteOutcome {
        guard let after else { return .partial }
        if after == before { return chunk.isEmpty ? .all : .none }
        guard let expected = LatchSelfTest.splice(before.value, at: before.caret, insert: chunk),
              after.value == expected, after.caret == before.caret + chunk.utf16.count
        else { return .partial }
        return .all
    }

    /// Type the chunk the normal way only after a proven no-op. After `.all`
    /// it is already in; after `.partial` typing could double it.
    public static func needsTypedFallback(_ outcome: AXWriteOutcome) -> Bool { outcome == .none }
}

/// Text-free tally for one (bundle ID, field role) at one app version.
public struct LatchPassiveRecord: Codable, Sendable, Equatable {
    public var bundleID: String
    public var fieldRole: String
    public var appVersion: [Int]?
    public var successes: Int
    public var noOps: Int
    public var partials: Int
    public var lastObserved: Date

    public enum Verdict: Sendable, Equatable {
        /// Fewer than the threshold clean inserts so far.
        case learning(successes: Int)
        /// Frontmost AX insert proven; still needs the self-test for the
        /// background criteria.
        case candidate
        /// At least one silent no-op: AX delivery doesn't fully work here.
        case notCapable
        /// At least one partial / unverifiable write: never latch.
        case unsafe
    }

    public var verdict: Verdict {
        if partials > 0 { return .unsafe }
        if noOps > 0 { return .notCapable }
        if successes >= LatchPassiveLearning.candidateThreshold { return .candidate }
        return .learning(successes: successes)
    }
}

/// All passive records, keyed "bundleID|fieldRole". Pure value type.
public struct LatchPassiveLedger: Codable, Sendable, Equatable {
    public var records: [String: LatchPassiveRecord] = [:]
    public init() {}

    public enum Status: Sendable, Equatable {
        case unobserved
        case recheckNeeded
        case observed(LatchPassiveRecord.Verdict)
    }

    static func key(_ bundleID: String, _ role: String) -> String { "\(bundleID)|\(role)" }

    /// Record one attempt. A different app version starts the tally over
    /// (LATCH_FEASIBILITY.md: local entries are version-tied).
    public mutating func observe(bundleID: String, fieldRole: String, appVersion: [Int]?,
                                 outcome: AXWriteOutcome, now: Date = Date()) {
        let k = Self.key(bundleID, fieldRole)
        var r = records[k]
        if r == nil || r?.appVersion != appVersion {
            r = LatchPassiveRecord(bundleID: bundleID, fieldRole: fieldRole, appVersion: appVersion,
                                   successes: 0, noOps: 0, partials: 0, lastObserved: now)
        }
        switch outcome {
        case .all: r!.successes += 1
        case .none: r!.noOps += 1
        case .partial: r!.partials += 1
        }
        r!.lastObserved = now
        records[k] = r
    }

    public func status(bundleID: String, fieldRole: String, appVersion: [Int]?) -> Status {
        guard let r = records[Self.key(bundleID, fieldRole)] else { return .unobserved }
        guard let v = appVersion, r.appVersion == v else { return .recheckNeeded }
        return .observed(r.verdict)
    }
}

/// ~/Library/Application Support/Susurro/latch-passive.json
public struct LatchPassiveStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var standard: LatchPassiveStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LatchPassiveStore(fileURL: base.appendingPathComponent("Susurro/latch-passive.json"))
    }

    public func load() -> LatchPassiveLedger {
        guard let data = try? Data(contentsOf: fileURL) else { return LatchPassiveLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LatchPassiveLedger.self, from: data)) ?? LatchPassiveLedger()
    }

    public func save(_ ledger: LatchPassiveLedger) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(ledger).write(to: fileURL, options: .atomic)
    }
}
