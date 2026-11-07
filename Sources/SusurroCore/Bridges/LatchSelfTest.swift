import Foundation

// Guided "Test <app>" self-test (BEA-693; docs/BRIDGES.md "Self-test").
// From the "Latching isn't supported in <app>" pill the user can ask
// Susurro to probe the app: the caret goes in a scratch field, Susurro runs
// the four-criteria probe and records the result locally.
//
// Core only: the probe sequence runs against a `LatchProbeDriver` seam (AX /
// postToPid implementations belong in the app target), and the record is a
// local JSON file. A local pass is ADVISORY in this build: it does not feed
// `LatchPolicy.engage`, because no validating delivery path for non-bridge
// apps exists yet (the AX bridge failed TextEdit's undo check, BEA-691), and
// latch is full support or nothing. See `LatchSelfTestStore.admitsLatch`.

/// The four criteria (LATCH_FEASIBILITY.md "Capability detection").
public enum LatchProbeCriterion: String, Codable, Sendable, CaseIterable {
    /// A marker written while another app is in front lands in the field,
    /// proved by reading the value back (never by an API return code).
    case backgroundDelivery
    /// The remembered element is still the same, valid element after the app
    /// loses focus, and the caret did not move.
    case identity
    /// The exact marker reads back at the caret (and is gone after removal).
    case readBack
    /// Value and caret/selection are readable (smart spacing, joins).
    case context
}

/// One probe step's evidence: which criterion, whether it held, and a
/// text-free reason (never field content).
public struct LatchProbeCheck: Codable, Sendable, Equatable {
    public var criterion: LatchProbeCriterion
    public var passed: Bool
    public var reason: String
    public init(_ criterion: LatchProbeCriterion, passed: Bool, reason: String) {
        self.criterion = criterion
        self.passed = passed
        self.reason = reason
    }
}

/// The side effects the probe needs, implemented per delivery method in the
/// app target (fakes in tests). Calls block; run off the main thread.
public protocol LatchProbeDriver: Sendable {
    /// Pin the focused element of the scratch field (app is frontmost).
    func pinFocusedField() -> Bool
    /// Bring Susurro forward so the target is in the background.
    func moveTargetToBackground() -> Bool
    /// The pinned element still resolves to the same element.
    func pinnedElementIsValid() -> Bool
    /// The field's value and caret offset (UTF-16), nil if unreadable.
    func readContext() -> (value: String, caret: Int)?
    /// Insert `text` at the pinned caret via this driver's delivery method.
    func deliver(_ text: String) -> Bool
    /// Remove `count` UTF-16 units before the caret (the marker).
    func removeBeforeCaret(_ count: Int) -> Bool
}

/// The result of one self-test of one app version.
public struct LatchSelfTestResult: Codable, Sendable, Equatable {
    public var bundleID: String
    public var appVersion: [Int]?
    public var method: BridgeID
    public var date: Date
    public var checks: [LatchProbeCheck]
    /// The marker could not be removed: the user must delete it by hand.
    public var markerLeftBehind: Bool

    /// Full support or nothing: every criterion must have passed.
    public var passed: Bool {
        LatchProbeCriterion.allCases.allSatisfy { c in checks.contains { $0.criterion == c && $0.passed } }
            && !checks.contains { !$0.passed }
    }

    /// Pill shown when the self-test finishes.
    public func pill(appName: String) -> String {
        if markerLeftBehind { return "Test of \(appName) left a marker in the field — please delete it" }
        if passed { return "\(appName) passed the latch test" }
        let failed = checks.first { !$0.passed }?.criterion
        let why: String
        switch failed {
        case .backgroundDelivery?: why = "text didn't arrive in the background"
        case .identity?: why = "the field changed when \(appName) lost focus"
        case .readBack?: why = "the text couldn't be confirmed"
        case .context?: why = "the field couldn't be read"
        case nil: why = "the test didn't finish"
        }
        return "\(appName) failed the latch test: \(why)"
    }
}

public enum LatchSelfTest {
    /// Pill action offered next to "Latching isn't supported in <app>".
    public static func actionTitle(appName: String) -> String { "Test \(appName)" }

    /// Instruction shown before the probe starts.
    public static func instruction(appName: String) -> String {
        "Put the caret in an empty scratch field in \(appName), then click Start. Susurro types a short marker and removes it."
    }

    /// A marker that can't be mistaken for dictation; `nonce` comes from
    /// Susurro (LatchToken), never from input.
    public static func marker(nonce: Int) -> String { "\u{200B}susurro-probe-\(nonce)\u{200B}" }

    /// Run the probe. Stops at the first failed criterion; always tries to
    /// remove the marker once it may have been delivered.
    public static func run(bundleID: String, appVersion: [Int]?, method: BridgeID,
                           driver: any LatchProbeDriver, nonce: Int,
                           now: Date = Date()) -> LatchSelfTestResult {
        var checks: [LatchProbeCheck] = []
        var left = false
        func result() -> LatchSelfTestResult {
            LatchSelfTestResult(bundleID: bundleID, appVersion: appVersion, method: method, date: now,
                                checks: checks, markerLeftBehind: left)
        }
        guard driver.pinFocusedField() else {
            checks.append(.init(.identity, passed: false, reason: "no focused field to pin"))
            return result()
        }
        guard let before = driver.readContext() else {
            checks.append(.init(.context, passed: false, reason: "value or caret unreadable"))
            return result()
        }
        checks.append(.init(.context, passed: true, reason: "value and caret readable"))
        guard driver.moveTargetToBackground() else {
            checks.append(.init(.backgroundDelivery, passed: false, reason: "couldn't move the target to the background"))
            return result()
        }
        guard driver.pinnedElementIsValid(), let still = driver.readContext(), still.caret == before.caret else {
            checks.append(.init(.identity, passed: false, reason: "element stale or caret moved after focus loss"))
            return result()
        }
        checks.append(.init(.identity, passed: true, reason: "element valid, caret unchanged"))

        let mark = marker(nonce: nonce)
        let n = mark.utf16.count
        let delivered = driver.deliver(mark)
        guard let after = driver.readContext() else {
            checks.append(.init(.backgroundDelivery, passed: false, reason: "no read-back after delivery"))
            left = delivered && !driver.removeBeforeCaret(n)
            return result()
        }
        let expected = splice(before.value, at: before.caret, insert: mark)
        let landed = after.value == expected
        let caretOK = after.caret == before.caret + n
        let changed = after.value != before.value
        if !landed {
            checks.append(.init(.backgroundDelivery, passed: false,
                                reason: changed ? "field changed, but not by exactly the marker" : "nothing arrived (API return ignored)"))
            // Only undo what we can prove is ours: an unexplained change is
            // left alone and reported, never "fixed" with blind deletes.
            left = changed
            return result()
        }
        checks.append(.init(.backgroundDelivery, passed: true, reason: "marker landed in the background"))
        checks.append(.init(.readBack, passed: caretOK, reason: caretOK ? "exact read-back, caret after marker" : "caret not after the marker"))
        let removed = driver.removeBeforeCaret(n) && driver.readContext()?.value == before.value
        left = !removed
        if !removed { checks.append(.init(.readBack, passed: false, reason: "marker removal not confirmed")) }
        return result()
    }

    static func splice(_ value: String, at caret: Int, insert: String) -> String? {
        let u = Array(value.utf16)
        guard caret >= 0, caret <= u.count else { return nil }
        return String(utf16CodeUnits: Array(u[..<caret]) + Array(insert.utf16) + Array(u[caret...]), count: u.count + insert.utf16.count)
    }
}

/// Local self-test results, one per bundle ID, in a JSON file. Version-tied:
/// a pass for another app version reads as `.recheckNeeded`.
public struct LatchSelfTestStore: Sendable {
    public enum Status: Sendable, Equatable {
        case untested, passed, failed, recheckNeeded
    }

    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    /// ~/Library/Application Support/Susurro/latch-selftests.json
    public static var standard: LatchSelfTestStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LatchSelfTestStore(fileURL: base.appendingPathComponent("Susurro/latch-selftests.json"))
    }

    public func load() -> [String: LatchSelfTestResult] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: LatchSelfTestResult].self, from: data)) ?? [:]
    }

    public func record(_ result: LatchSelfTestResult) throws {
        var all = load()
        all[result.bundleID] = result
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(all).write(to: fileURL, options: .atomic)
    }

    public func status(bundleID: String, appVersion: [Int]?) -> Status {
        guard let r = load()[bundleID] else { return .untested }
        guard r.passed else { return .failed }
        guard let v = appVersion, r.appVersion == v else { return .recheckNeeded }
        return .passed
    }

    /// Whether a local pass may engage latch. Always false in this build
    /// (open decision, BEA-693): no validating delivery path exists for
    /// non-bridge apps, so a pass is recorded but advisory. A remote
    /// revocation would override it anyway (LATCH_FEASIBILITY.md).
    public static let admitsLatch = false
}
