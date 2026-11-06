import Foundation
import Testing
@testable import SusurroCore

/// Records every bridge call, in order; can fail and be slow.
private final class RecordingTarget: LatchTarget, @unchecked Sendable {
    let pin = LatchPin(method: .emacsServer, bundleID: "org.gnu.Emacs", appName: "Emacs",
                       documentName: "*scratch*", handle: "1", documentNoun: "buffer")
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    var alive = true
    var insertDelay: TimeInterval = 0
    func log(_ e: String) { lock.withLock { _events.append(e) } }
    func context() -> LatchBridgeReply { log("context"); return alive ? .value("ctx") : .gone }
    func insert(_ text: String) -> LatchBridgeReply {
        log("insert-start \(text)")
        if insertDelay > 0 { Thread.sleep(forTimeInterval: insertDelay) }
        log("insert-end \(text)")
        return alive ? .value(text) : .gone
    }
    func release() { log("release") }
}

@Suite struct LatchSessionTests {
    @Test func deliversWhileAlive() async {
        let t = RecordingTarget()
        let s = LatchSession(target: t)
        let r = await s.deliver(" one.")
        #expect(r == .init(outcome: .delivered, endedNow: false, clipboardText: nil))
        #expect(await s.context() == .value("ctx"))
    }

    /// Defect 2: one pill, appended clipboard text, no bridge calls after the end.
    @Test func firstFailureEndsOnceAndClipboardAccumulates() async {
        let t = RecordingTarget()
        let s = LatchSession(target: t)
        t.alive = false
        let a = await s.deliver(" one.")
        #expect(a == .init(outcome: .failed(.targetGone), endedNow: true, clipboardText: " one."))
        let callsAfterEnd = t.events.count
        let b = await s.deliver(" two.")
        #expect(b == .init(outcome: .failed(.targetGone), endedNow: false, clipboardText: " one. two."))
        #expect(await s.context() == .gone)
        #expect(t.events.count == callsAfterEnd)   // nothing reached the app
    }

    @Test func contextFailureAlsoEndsOnce() async {
        let s = LatchSession(target: RecordingTarget())
        let a = await s.fail(" one.", because: .bridgeUnavailable)
        #expect(a.endedNow && a.clipboardText == " one.")
        let b = await s.fail(" two.", because: .targetGone)
        #expect(!b.endedNow && b.clipboardText == " one. two." && b.outcome == .failed(.bridgeUnavailable))
    }

    /// Defect 3: release is ordered after an in-flight insert, never during it.
    @Test func releaseWaitsForInFlightInsert() async {
        let t = RecordingTarget()
        t.insertDelay = 0.3
        let s = LatchSession(target: t)
        let insert = Task { await s.deliver(" slow.") }
        try? await Task.sleep(for: .milliseconds(50))
        await s.release()
        _ = await insert.value
        #expect(t.events == ["insert-start  slow.", "insert-end  slow.", "release"])
    }

    @Test func releaseIsIdempotentAndBlocksLaterCalls() async {
        let t = RecordingTarget()
        let s = LatchSession(target: t)
        await s.release()
        await s.release()
        let r = await s.deliver(" late.")
        #expect(r.outcome == .failed(.targetGone) && r.clipboardText == " late.")
        #expect(t.events == ["release"])
    }

    /// Defect 4: bridge calls run on the session's own queue, not the main
    /// thread or the cooperative pool.
    @Test func callsRunOnTheSessionQueue() async {
        final class ThreadProbe: LatchTarget, @unchecked Sendable {
            let pin = LatchPin(method: .emacsServer, bundleID: "b", appName: "a", documentName: "d", handle: "1")
            var label = ""
            func context() -> LatchBridgeReply { .value("") }
            func insert(_ text: String) -> LatchBridgeReply {
                label = String(cString: __dispatch_queue_get_label(nil)); return .value(text)
            }
            func release() {}
        }
        let p = ThreadProbe()
        _ = await LatchSession(target: p).deliver("x")
        #expect(p.label == "com.mtwomey.susurro.latch")
    }
}
