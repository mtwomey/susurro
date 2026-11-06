import Foundation
import Testing
@testable import SusurroCore

@MainActor
final class FakeInserter: Inserter {
    var log: [String] = []
    var failTyping = false
    func type(_ text: String) -> Bool { log.append("type:\(text)"); return !failTyping }
    func deleteBackward(_ count: Int) { log.append("delete:\(count)") }
}

@MainActor
final class FakeFrontmost: FrontmostAppProvider {
    var frontmostPID: pid_t?
    var secureInputActive = false
    init(_ pid: pid_t?) { frontmostPID = pid }
}

@MainActor
final class FakeClipboard: Clipboard {
    var contents: [String] = []
    func set(_ text: String) { contents.append(text) }
}

@MainActor
@Suite struct InsertExecutorTests {
    let inserter = FakeInserter(), front = FakeFrontmost(7), clipboard = FakeClipboard()
    var executor: InsertExecutor { InsertExecutor(inserter: inserter, frontmost: front, clipboard: clipboard) }

    @Test func typesAndRemembers() {
        let ex = executor
        let r = ex.insert("Hello there.", deleteBackward: 0, frontmostPID: 7, secureInput: false,
                          copyToClipboard: false, position: nil, continuesTail: true)
        #expect(r.typed && r.recorded && r.toast == nil)
        #expect(inserter.log == ["type:Hello there."])
        #expect(clipboard.contents.isEmpty)
        #expect(ex.memory.tailIfStillFocused(pid: 7) != nil)
    }

    /// Shown hands-free mark: Delete first, then the joined text; memory
    /// sees the retraction.
    @Test func shownMarkRetractDeletesBeforeTyping() {
        let ex = executor
        _ = ex.insert("one.", deleteBackward: 0, frontmostPID: 7, secureInput: false,
                      copyToClipboard: false, position: nil, continuesTail: true)
        _ = ex.insert(" two", deleteBackward: 1, frontmostPID: 7, secureInput: false,
                      copyToClipboard: false, position: nil, continuesTail: true)
        #expect(inserter.log == ["type:one.", "delete:1", "type: two"])
        #expect(ex.memory.tailIfStillFocused(pid: 7)?.hasSuffix("one two") == true)
    }

    @Test func secureInputCopiesClearsMemoryAndToasts() {
        let ex = executor
        _ = ex.insert("before", deleteBackward: 0, frontmostPID: 7, secureInput: false,
                      copyToClipboard: false, position: nil, continuesTail: true)
        let r = ex.insert("secret", deleteBackward: 0, frontmostPID: 7, secureInput: true,
                          copyToClipboard: false, position: nil, continuesTail: true)
        #expect(!r.recorded)
        #expect(r.toast == InsertExecutor.secureInputToast)
        #expect(clipboard.contents == ["secret"])
        #expect(ex.memory.tailIfStillFocused(pid: 7) == nil)
    }

    @Test func copySettingCopiesWithoutToast() {
        let r = executor.insert("hi", deleteBackward: 0, frontmostPID: 7, secureInput: false,
                                copyToClipboard: true, position: nil, continuesTail: true)
        #expect(r.recorded && r.toast == nil && clipboard.contents == ["hi"])
    }

    @Test func failedKeystrokeForgetsTail() {
        let ex = executor
        _ = ex.insert("before", deleteBackward: 0, frontmostPID: 7, secureInput: false,
                      copyToClipboard: false, position: nil, continuesTail: true)
        inserter.failTyping = true
        let r = ex.insert("lost", deleteBackward: 0, frontmostPID: 7, secureInput: false,
                          copyToClipboard: false, position: nil, continuesTail: true)
        #expect(!r.typed && !r.recorded)
        #expect(ex.memory.tailIfStillFocused(pid: 7) == nil)
    }

    @Test func appSwitchGoesToClipboardNotKeystrokes() {
        let ex = executor
        _ = ex.insert("before", deleteBackward: 0, frontmostPID: 7, secureInput: false,
                      copyToClipboard: false, position: nil, continuesTail: true)
        inserter.log = []
        #expect(ex.copyAfterAppSwitch("late words.") == InsertExecutor.appSwitchToast)
        #expect(inserter.log.isEmpty)
        #expect(clipboard.contents == ["late words."])
        #expect(ex.memory.tailIfStillFocused(pid: 7) == nil)
    }

    @Test func heldMarkTailRemembered() {
        let ex = executor
        ex.typeHeldMark(".", sessionPID: 7)
        #expect(inserter.log == ["type:."])
        #expect(ex.memory.tailIfStillFocused(pid: 7) == ".")
        front.frontmostPID = 9
        ex.typeHeldMark("?", sessionPID: 7)
        #expect(inserter.log == ["type:."])
    }
}

@MainActor
@Suite struct InsertionQueueTests {
    /// F3: a slow first dictation must still type before a fast second one.
    @Test func testFIFOOrderingDespiteVariableLatency() async {
        let queue = InsertionQueue(), inserter = FakeInserter()
        let delays: [UInt64] = [60, 0, 20, 0] // ms: the first job is the slowest
        for (i, d) in delays.enumerated() {
            queue.enqueue {
                try? await Task.sleep(nanoseconds: d * 1_000_000)
                _ = inserter.type("\(i)")
            }
        }
        #expect(queue.pending == 4)
        await queue.drain()
        #expect(inserter.log == ["type:0", "type:1", "type:2", "type:3"])
        #expect(queue.pending == 0)
    }

    /// PTT and hands-free share one queue: a PTT release after a hands-free
    /// stop waits for the hands-free tail (held mark) to be typed.
    @Test func testPTTWaitsForHandsFreeTail() async {
        let queue = InsertionQueue(), inserter = FakeInserter(), front = FakeFrontmost(42)
        queue.enqueue {
            try? await Task.sleep(nanoseconds: 30_000_000)
            _ = inserter.type("chunk")
        }
        queue.enqueue {
            _ = HeldMarkTail.type(mark: ".", sessionPID: 42, frontmost: front, inserter: inserter)
        }
        queue.enqueue { _ = inserter.type(" ptt") }
        await queue.drain()
        #expect(inserter.log == ["type:chunk", "type:.", "type: ptt"])
    }

    /// Cancel: jobs whose gate went stale before their turn never run; jobs
    /// from other triggers (PTT, always current) still do.
    @Test func testCancelledJobsAreSkipped() async {
        let queue = InsertionQueue(), inserter = FakeInserter()
        var gate = SessionGate()
        let token = gate.token
        queue.enqueue {
            try? await Task.sleep(nanoseconds: 30_000_000)
            _ = inserter.type("first")
        }
        queue.enqueue(isCurrent: { gate.isCurrent(token) }) { _ = inserter.type("hf1") }
        queue.enqueue(isCurrent: { gate.isCurrent(token) }) { _ = inserter.type("hf2") }
        queue.enqueue { _ = inserter.type("ptt") }
        gate.cancel() // Esc while the first job is still running
        await queue.drain()
        #expect(inserter.log == ["type:first", "type:ptt"])
        #expect(queue.pending == 0)
    }

    @Test func testHeldMarkTypedOnlyIntoSessionApp() {
        let inserter = FakeInserter(), front = FakeFrontmost(7)
        #expect(HeldMarkTail.type(mark: ".", sessionPID: 8, frontmost: front, inserter: inserter) == nil,
                "app switch: the mark must not land in another app")
        #expect(inserter.log == [])
        #expect(HeldMarkTail.type(mark: ".", sessionPID: 7, frontmost: front, inserter: inserter) == ".")
        #expect(inserter.log == ["type:."])
    }

    @Test func testHeldMarkNotTypedThroughSecureInput() {
        let inserter = FakeInserter(), front = FakeFrontmost(7)
        front.secureInputActive = true
        #expect(HeldMarkTail.type(mark: "?", sessionPID: 7, frontmost: front, inserter: inserter) == nil)
        #expect(inserter.log == [])
    }

    @Test func testHeldMarkNoMarkOrFailedTypingRecordsNothing() {
        let inserter = FakeInserter(), front = FakeFrontmost(7)
        #expect(HeldMarkTail.type(mark: nil, sessionPID: 7, frontmost: front, inserter: inserter) == nil)
        inserter.failTyping = true
        #expect(HeldMarkTail.type(mark: ".", sessionPID: 7, frontmost: front, inserter: inserter) == nil)
    }
}
