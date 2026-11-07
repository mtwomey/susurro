import Foundation
import Testing
@testable import SusurroCore

/// BEA-694: passive AX learning (outcome classifier, fallback rule, ledger).
@Suite struct LatchPassiveLearningTests {
    let before = AXFieldSnapshot(value: "Hello world", caret: 5)

    @Test func cleanInsertIsAll() {
        let after = AXFieldSnapshot(value: "Hello there world", caret: 11)
        #expect(LatchPassiveLearning.classify(before: before, chunk: " there", after: after) == .all)
    }

    @Test func unchangedFieldIsNone() {
        #expect(LatchPassiveLearning.classify(before: before, chunk: " there", after: before) == .none)
    }

    @Test func unreadableReadBackIsPartial() {
        #expect(LatchPassiveLearning.classify(before: before, chunk: " there", after: nil) == .partial)
    }

    @Test func truncatedInsertIsPartial() {
        let after = AXFieldSnapshot(value: "Hello the world", caret: 9)
        #expect(LatchPassiveLearning.classify(before: before, chunk: " there", after: after) == .partial)
    }

    @Test func rightTextWrongCaretIsPartial() {
        let after = AXFieldSnapshot(value: "Hello there world", caret: 5)
        #expect(LatchPassiveLearning.classify(before: before, chunk: " there", after: after) == .partial)
    }

    @Test func doubledInsertIsPartial() {
        let after = AXFieldSnapshot(value: "Hello there there world", caret: 17)
        #expect(LatchPassiveLearning.classify(before: before, chunk: " there", after: after) == .partial)
    }

    @Test func caretOnlyMoveIsPartial() {
        let after = AXFieldSnapshot(value: "Hello world", caret: 0)
        #expect(LatchPassiveLearning.classify(before: before, chunk: " there", after: after) == .partial)
    }

    @Test func utf16CaretWithEmoji() {
        let b = AXFieldSnapshot(value: "👋 hi", caret: 2)
        let a = AXFieldSnapshot(value: "👋 🎉 hi", caret: 5)
        #expect(LatchPassiveLearning.classify(before: b, chunk: " 🎉", after: a) == .all)
    }

    @Test func fallbackOnlyAfterProvenNoOp() {
        #expect(LatchPassiveLearning.needsTypedFallback(.none))
        #expect(!LatchPassiveLearning.needsTypedFallback(.all))
        #expect(!LatchPassiveLearning.needsTypedFallback(.partial))
    }

    @Test func attemptGate() {
        #expect(LatchPassiveLearning.shouldAttempt(selectedTextSettable: true, contextReadable: true,
                                                   secureField: false, secureInput: false))
        #expect(!LatchPassiveLearning.shouldAttempt(selectedTextSettable: false, contextReadable: true,
                                                    secureField: false, secureInput: false))
        #expect(!LatchPassiveLearning.shouldAttempt(selectedTextSettable: true, contextReadable: false,
                                                    secureField: false, secureInput: false))
        #expect(!LatchPassiveLearning.shouldAttempt(selectedTextSettable: true, contextReadable: true,
                                                    secureField: true, secureInput: false))
        #expect(!LatchPassiveLearning.shouldAttempt(selectedTextSettable: true, contextReadable: true,
                                                    secureField: false, secureInput: true))
    }

    @Test func offAndAdvisoryByDefault() {
        #expect(LatchPassiveLearning.enabledByDefault == false)
        #expect(LatchPassiveLearning.admitsLatch == false)
    }

    @Test func ledgerReachesCandidateAfterThreshold() {
        var l = LatchPassiveLedger()
        let n = LatchPassiveLearning.candidateThreshold
        for _ in 0..<(n - 1) { l.observe(bundleID: "com.apple.TextEdit", fieldRole: "AXTextArea", appVersion: [1, 19], outcome: .all) }
        #expect(l.status(bundleID: "com.apple.TextEdit", fieldRole: "AXTextArea", appVersion: [1, 19]) == .observed(.learning(successes: n - 1)))
        l.observe(bundleID: "com.apple.TextEdit", fieldRole: "AXTextArea", appVersion: [1, 19], outcome: .all)
        #expect(l.status(bundleID: "com.apple.TextEdit", fieldRole: "AXTextArea", appVersion: [1, 19]) == .observed(.candidate))
    }

    @Test func oneNoOpMeansNotCapable() {
        var l = LatchPassiveLedger()
        for _ in 0..<10 { l.observe(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1], outcome: .all) }
        l.observe(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1], outcome: .none)
        #expect(l.status(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1]) == .observed(.notCapable))
    }

    @Test func onePartialIsUnsafeAndSticky() {
        var l = LatchPassiveLedger()
        l.observe(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1], outcome: .partial)
        for _ in 0..<10 { l.observe(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1], outcome: .all) }
        #expect(l.status(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1]) == .observed(.unsafe))
    }

    @Test func fieldRolesAreSeparate() {
        var l = LatchPassiveLedger()
        l.observe(bundleID: "a", fieldRole: "AXTextField", appVersion: [1], outcome: .none)
        l.observe(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1], outcome: .all)
        #expect(l.status(bundleID: "a", fieldRole: "AXTextField", appVersion: [1]) == .observed(.notCapable))
        #expect(l.status(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1]) == .observed(.learning(successes: 1)))
        #expect(l.status(bundleID: "a", fieldRole: "AXComboBox", appVersion: [1]) == .unobserved)
    }

    @Test func versionChangeNeedsRecheckThenStartsOver() {
        var l = LatchPassiveLedger()
        l.observe(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1], outcome: .partial)
        #expect(l.status(bundleID: "a", fieldRole: "AXTextArea", appVersion: [2]) == .recheckNeeded)
        #expect(l.status(bundleID: "a", fieldRole: "AXTextArea", appVersion: nil) == .recheckNeeded)
        l.observe(bundleID: "a", fieldRole: "AXTextArea", appVersion: [2], outcome: .all)
        #expect(l.status(bundleID: "a", fieldRole: "AXTextArea", appVersion: [2]) == .observed(.learning(successes: 1)))
    }

    @Test func storeRoundTripIsTextFree() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("passive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LatchPassiveStore(fileURL: dir.appendingPathComponent("latch-passive.json"))
        #expect(store.load() == LatchPassiveLedger())
        let secret = "my secret dictation"
        let outcome = LatchPassiveLearning.classify(before: AXFieldSnapshot(value: "", caret: 0), chunk: secret,
                                                    after: AXFieldSnapshot(value: secret, caret: secret.utf16.count))
        var l = LatchPassiveLedger()
        l.observe(bundleID: "a", fieldRole: "AXTextArea", appVersion: [1], outcome: outcome,
                  now: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(l)
        #expect(store.load() == l)
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!raw.contains("secret"))
        #expect(Set(Mirror(reflecting: l.records.values.first!).children.compactMap(\.label))
                == ["bundleID", "fieldRole", "appVersion", "successes", "noOps", "partials", "lastObserved"])
    }
}
