import Foundation
import Testing
@testable import SusurroCore

/// BEA-695: iTerm AppleScript delivery shape (codec only; not a bridge).
@Suite struct ITermScriptTests {
    @Test func textTravelsAsArgvNeverInSource() throws {
        let hostile = "\" & (do shell script \"rm -rf ~\") & \""
        let args = try #require(ITermScript.writeArguments(sessionID: "ABC-123", text: hostile))
        #expect(args == ["-e", ITermScript.write, "--", "ABC-123", hostile])
        #expect(!ITermScript.write.contains(hostile))
    }

    @Test func scriptNeverAppendsNewlineAndAddressesPinnedSession() {
        #expect(ITermScript.write.contains("newline no"))
        #expect(!ITermScript.write.contains("current session"))
        #expect(ITermScript.write.contains("(id of s) is sid"))
    }

    @Test func newlineInTextIsRefusedBecauseItWouldExecute() {
        #expect(ITermScript.writeArguments(sessionID: "A", text: "ls\n") == nil)
        #expect(ITermScript.writeArguments(sessionID: "A", text: "ls\r") == nil)
        #expect(ITermScript.writeArguments(sessionID: "A", text: "ls\r\n") == nil)
        #expect(ITermScript.writeArguments(sessionID: "A", text: "hello world") != nil)
    }

    @Test(arguments: ["", "a b", "x;y", "w0t0p0\"", String(repeating: "a", count: 65), "é"])
    func invalidSessionIDsAreRefused(_ id: String) {
        #expect(!ITermScript.isValidSessionID(id))
        #expect(ITermScript.writeArguments(sessionID: id, text: "hi") == nil)
    }

    @Test func uuidShapedSessionIDsAreAccepted() {
        #expect(ITermScript.isValidSessionID("w0t0p0:6F1A2B3C-0000-4D5E-8F90-ABCDEF012345"))
    }

    @Test func iTermIsLatchOnlyAndNotAllowlisted() {
        // BEA-700: registered as a latch bridge, but not allowlisted until a
        // read-back source exists and the live suite passes.
        #expect(BridgeRegistry.standard.contextReader(for: ITermScript.bundleID) == nil)
        #expect(BridgeRegistry.standard.latchBridge(.itermSession) != nil)
        #expect(LatchAllowlist.bundled.entry(for: ITermScript.bundleID) == nil)
        #expect(LatchAllowlist.bundled.entry(for: "com.apple.Terminal") == nil)
        #expect(LatchAllowlist.bundled.entry(for: "com.microsoft.VSCode") == nil)
        #expect(LatchAllowlist.bundled.entry(for: "com.apple.Notes") == nil)
    }
}
