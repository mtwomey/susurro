import Foundation
import Testing
@testable import SusurroCore

/// BEA-693: guided "Test <app>" self-test (four-criteria probe + local record).
@Suite struct LatchSelfTestTests {
    /// A scratch field. Flags simulate each way an app can fail a criterion.
    final class FakeField: LatchProbeDriver, @unchecked Sendable {
        let lock = NSLock()
        var value: String
        var caret: Int
        var canPin = true, readable = true, staleAfterBlur = false, caretJumpsOnBlur = false
        var deliveryNoOp = false, deliveryMangles = false, removeFails = false
        var blurred = false
        init(_ value: String = "abc", caret: Int = 3) { self.value = value; self.caret = caret }

        func pinFocusedField() -> Bool { canPin }
        func moveTargetToBackground() -> Bool {
            lock.withLock { blurred = true; if caretJumpsOnBlur { caret = 0 } }
            return true
        }
        func pinnedElementIsValid() -> Bool { !staleAfterBlur }
        func readContext() -> (value: String, caret: Int)? {
            lock.withLock { readable ? (value, caret) : nil }
        }
        func deliver(_ text: String) -> Bool {
            lock.withLock {
                if deliveryNoOp { return true } // returns success, inserts nothing
                let t = deliveryMangles ? String(text.dropLast()) : text
                value = LatchSelfTest.splice(value, at: caret, insert: t)!
                caret += t.utf16.count
                return true
            }
        }
        func removeBeforeCaret(_ count: Int) -> Bool {
            lock.withLock {
                if removeFails { return false }
                var u = Array(value.utf16)
                u.removeSubrange((caret - count)..<caret)
                value = String(utf16CodeUnits: u, count: u.count)
                caret -= count
                return true
            }
        }
    }

    func run(_ f: FakeField) -> LatchSelfTestResult {
        LatchSelfTest.run(bundleID: "com.example.app", appVersion: [2, 1], method: .axSelectedText,
                          driver: f, nonce: 123_000_001, now: Date(timeIntervalSince1970: 0))
    }

    @Test func passesWhenAllFourHoldAndRemovesTheMarker() {
        let f = FakeField("héllo 👋", caret: 3)
        let r = run(f)
        #expect(r.passed)
        #expect(Set(r.checks.map(\.criterion)) == Set(LatchProbeCriterion.allCases))
        #expect(!r.markerLeftBehind)
        #expect(f.value == "héllo 👋" && f.caret == 3)
        #expect(r.pill(appName: "App") == "App passed the latch test")
    }

    @Test func successReturnThatInsertsNothingFailsBackgroundDelivery() {
        let f = FakeField(); f.deliveryNoOp = true
        let r = run(f)
        #expect(!r.passed)
        #expect(r.checks.last == LatchProbeCheck(.backgroundDelivery, passed: false, reason: "nothing arrived (API return ignored)"))
        #expect(!r.markerLeftBehind)
        #expect(r.pill(appName: "App") == "App failed the latch test: text didn't arrive in the background")
    }

    @Test func partialInsertIsReportedAndNeverBlindDeleted() {
        let f = FakeField(); f.deliveryMangles = true
        let r = run(f)
        #expect(!r.passed)
        #expect(r.markerLeftBehind)
        #expect(f.value != "abc") // left alone for the user, not guessed at
        #expect(r.pill(appName: "App").contains("left a marker"))
    }

    @Test func staleElementOrMovedCaretFailsIdentity() {
        let a = FakeField(); a.staleAfterBlur = true
        let b = FakeField(); b.caretJumpsOnBlur = true
        for f in [a, b] {
            let r = run(f)
            #expect(!r.passed)
            #expect(r.checks.last?.criterion == .identity)
            #expect(f.value == "abc") // nothing delivered
        }
    }

    @Test func unreadableFieldFailsContextBeforeAnyWrite() {
        let f = FakeField(); f.readable = false
        let r = run(f)
        #expect(r.checks == [LatchProbeCheck(.context, passed: false, reason: "value or caret unreadable")])
        #expect(f.value == "abc")
    }

    @Test func failedRemovalFailsTheTestAndFlagsTheMarker() {
        let f = FakeField(); f.removeFails = true
        let r = run(f)
        #expect(!r.passed)
        #expect(r.markerLeftBehind)
    }

    @Test func storeIsVersionTiedAndAdvisory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LatchSelfTestStore(fileURL: dir.appendingPathComponent("s.json"))
        #expect(store.status(bundleID: "com.example.app", appVersion: [2, 1]) == .untested)
        try store.record(run(FakeField()))
        #expect(store.status(bundleID: "com.example.app", appVersion: [2, 1]) == .passed)
        #expect(store.status(bundleID: "com.example.app", appVersion: [2, 2]) == .recheckNeeded)
        #expect(store.status(bundleID: "com.example.app", appVersion: nil) == .recheckNeeded)
        let bad = FakeField(); bad.deliveryNoOp = true
        try store.record(run(bad))
        #expect(store.status(bundleID: "com.example.app", appVersion: [2, 1]) == .failed)
        // Full support or nothing: a local pass never engages latch in this build.
        #expect(LatchSelfTestStore.admitsLatch == false)
        #expect(LatchPolicy.engage(LatchPinRequest(pid: 1, bundleID: "com.example.app", appName: "App", token: 1)).failureValue == .notAllowlisted)
    }

    @Test func recordIsTextFree() throws {
        let f = FakeField("secret words", caret: 6)
        let data = try JSONEncoder().encode(run(f))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("secret"))
        #expect(!json.contains("susurro-probe"))
    }

    @Test func pillCopy() {
        #expect(LatchSelfTest.actionTitle(appName: "Zen") == "Test Zen")
        #expect(LatchSelfTest.marker(nonce: 7).hasPrefix("\u{200B}susurro-probe-7"))
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
