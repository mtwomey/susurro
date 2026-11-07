import Foundation
import Testing
@testable import SusurroCore

/// BEA-700: iTerm2 latch bridge — program policy, screen read-back, and the
/// bridge against a fake osascript (no iTerm needed).
@Suite struct ITermLatchTests {
    @Test(arguments: ["zsh", "-zsh", "/bin/bash", "fish"]) func shellsAllowed(_ job: String) {
        #expect(ITermProgram.classify(job) == .shell)
        #expect(ITermProgram.classify(job).latchAllowed)
    }

    @Test(arguments: ["claude", "hermes", "codex"]) func agentsAllowed(_ job: String) {
        #expect(ITermProgram.classify(job) == .agentCLI)
    }

    @Test func editorsSshAndUnknownRefused() {
        for job in ["vim", "nvim", "nano", "emacs", "emacs-30.1", "ssh", "mosh-client", "tmux", "node", "python3", "less", ""] {
            #expect(!ITermProgram.classify(job).latchAllowed, "\(job)")
        }
        #expect(ITermProgram.refusalPill("vim").contains("editors"))
        #expect(ITermProgram.refusalPill("ssh").contains("ssh"))
    }

    @Test func textBeforeCursorJoinsSoftWrappedRows() {
        let rows = [ITermScreen.Row("old output", hardEOL: true),
                    ITermScreen.Row("% echo hello wor", hardEOL: false),
                    ITermScreen.Row("ld and more", hardEOL: true)]
        #expect(ITermScreen.textBeforeCursor(rows: rows, cursorX: 6, cursorY: 2) == "% echo hello world and")
        #expect(ITermScreen.textBeforeCursor(rows: rows, cursorX: 3, cursorY: 0) == "old")
        #expect(ITermScreen.textBeforeCursor(rows: rows, cursorX: 0, cursorY: 5) == nil)
    }

    @Test func cursorCountsWideCharactersAsTwoCells() {
        let rows = [ITermScreen.Row("> 日本語 ok", hardEOL: true)]
        #expect(ITermScreen.textBeforeCursor(rows: rows, cursorX: 6, cursorY: 0) == "> 日本")
    }

    @Test func readBackMatchesSuffixOrReportsTail() {
        #expect(ITermScreen.readBack(chunk: "world", before: "% hello world") == "world")
        #expect(ITermScreen.readBack(chunk: "world ", before: "% hello world") == "world ")
        #expect(ITermScreen.readBack(chunk: "world", before: "% hello wrld") != "world")
        #expect(LatchDelivery.verify(sent: "world", readBack: LatchReadBack(
            contextBefore: "", inserted: ITermScreen.readBack(chunk: "world", before: "xx"))) == .failed(.readBackMismatch))
    }

    @Test func parsesScriptReplies() {
        #expect(ITermScript.parseCurrent("w0t0p0:ABC-1\n-zsh\n")! == ("w0t0p0:ABC-1", "-zsh"))
        #expect(ITermScript.parseCurrent("none") == nil)
        #expect(ITermScript.parseStatus("alive\nclaude\n") == .alive(job: "claude"))
        #expect(ITermScript.parseStatus("gone") == .gone)
        #expect(ITermScript.parseStatus("huh") == nil)
        #expect(ITermScript.statusArguments(sessionID: "bad id") == nil)
    }

    // MARK: bridge with fakes

    final class FakeITerm: ITermScripting, ITermScreenReading, @unchecked Sendable {
        let lock = NSLock()
        var job = "zsh"
        var alive = true
        var line = "% "
        var writes: [String] = []
        var current: String? = "ABC-1\nzsh"

        func run(_ a: [String]) -> String? {
            lock.withLock {
                if a[1] == ITermScript.current { return current }
                if a[1] == ITermScript.status { return alive ? "alive\n\(job)" : "gone" }
                if a[1] == ITermScript.write {
                    guard alive else { return "gone" }
                    writes.append(a[4]); line += a[4]; return "ok"
                }
                return nil
            }
        }

        func screen(sessionID: String) -> (rows: [ITermScreen.Row], cursorX: Int, cursorY: Int)? {
            lock.withLock { ([ITermScreen.Row(line, hardEOL: true)], line.count, 0) }
        }
    }

    let request = LatchPinRequest(pid: 1, bundleID: ITermScript.bundleID, appName: "iTerm2", token: 1)

    @Test func pinsAllowedSessionAndDeliversWithReadBack() throws {
        let fake = FakeITerm()
        let target = try ITermBridge(scripting: fake, screen: fake).pin(request)
        #expect(target.pin.handle == "ABC-1")
        #expect(target.context() == .value("% "))
        #expect(LatchDelivery.deliver("echo hi", to: target) == .delivered)
        #expect(fake.writes == ["echo hi"])
    }

    @Test func refusesEditorAtPinAndWithoutReadBackSource() {
        let fake = FakeITerm()
        fake.current = "ABC-1\nvim"
        #expect(throws: BridgeError.noTarget) { try ITermBridge(scripting: fake, screen: fake).pin(request) }
        fake.current = "ABC-1\nzsh"
        #expect(throws: BridgeError.notEnabled) { try ITermBridge(scripting: fake, screen: nil).pin(request) }
        #expect(ITermBridge().refusalPill(for: .notEnabled)!.contains("Python API"))
    }

    @Test func programChangeOrClosedSessionEndsLatchWithoutWriting() throws {
        let fake = FakeITerm()
        let target = try ITermBridge(scripting: fake, screen: fake).pin(request)
        fake.job = "vim"
        #expect(LatchDelivery.deliver("dd", to: target) == .failed(.targetGone))
        fake.job = "bash"   // a different, also-allowed program is still a change
        #expect(LatchDelivery.deliver("x", to: target) == .failed(.targetGone))
        fake.job = "zsh"; fake.alive = false
        #expect(LatchDelivery.deliver("x", to: target) == .failed(.targetGone))
        #expect(fake.writes.isEmpty)
    }

    @Test func newlineChunkNeverWritten() throws {
        let fake = FakeITerm()
        let target = try ITermBridge(scripting: fake, screen: fake).pin(request)
        #expect(LatchDelivery.deliver("ls\n", to: target) == .failed(.bridgeUnavailable))
        #expect(fake.writes.isEmpty)
    }
}
