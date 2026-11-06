import Foundation
import Testing
@testable import SusurroCore

@Suite struct LatchAllowlistTests {
    @Test func bundledV1Allowlist() {
        let list = LatchAllowlist.bundled
        #expect(list.method(for: "md.obsidian") == .obsidianCLI)
        #expect(list.method(for: "org.gnu.Emacs") == .emacsServer)
        // TextEdit only after its undo check passes; Notes off; others off.
        #expect(list.method(for: "com.apple.TextEdit") == nil)
        #expect(list.method(for: "com.apple.Notes") == nil)
        #expect(list.method(for: "com.apple.Safari") == nil)
        #expect(list.method(for: nil) == nil)
    }

    @Test func entriesAreCodableForALaterRemoteList() throws {
        let data = try JSONEncoder().encode(LatchAllowlist.bundled.entries)
        let back = try JSONDecoder().decode([LatchCapability].self, from: data)
        #expect(back == LatchAllowlist.bundled.entries)
    }

    @Test func notSupportedPill() {
        #expect(LatchDelivery.notSupportedPill(appName: "Safari") == "Latching isn't supported in Safari")
    }
}

@Suite struct LatchDeliveryTests {
    let pin = LatchPin(method: .obsidianCLI, bundleID: "md.obsidian", appName: "Obsidian",
                       documentName: "Scratch", handle: "leaf-1|Scratch.md")

    @Test func deliveredWhenReadBackMatches() {
        let rb = LatchReadBack(contextBefore: "Hello", inserted: " world.")
        #expect(LatchDelivery.verify(sent: " world.", readBack: rb) == .delivered)
        #expect(LatchDelivery.actions(for: .delivered, sent: " world.", pin: pin).isEmpty)
    }

    @Test func mismatchCopiesPillsAndEndsLatch() {
        let rb = LatchReadBack(contextBefore: "", inserted: " wor")
        let outcome = LatchDelivery.verify(sent: " world.", readBack: rb)
        #expect(outcome == .failed(.readBackMismatch))
        let actions = LatchDelivery.actions(for: outcome, sent: " world.", pin: pin)
        #expect(actions.first == .copyToClipboard(" world."))
        #expect(actions.last == .endLatch)
        #expect(actions.count == 3)
    }

    @Test func targetGoneAndUnavailable() {
        #expect(LatchDelivery.verify(sent: "x", readBack: nil, targetAlive: false) == .failed(.targetGone))
        #expect(LatchDelivery.verify(sent: "x", readBack: nil) == .failed(.bridgeUnavailable))
        #expect(LatchDelivery.pillText(.targetGone, pin: pin) == "Latch ended: Obsidian closed the note — text copied")
        var emacs = pin; emacs.method = .emacsServer; emacs.appName = "Emacs"
        #expect(LatchDelivery.pillText(.targetGone, pin: emacs) == "Latch ended: Emacs closed the buffer — text copied")
    }

    @Test func emptyChunkFailureStillEndsLatchWithoutClipboard() {
        let actions = LatchDelivery.actions(for: .failed(.bridgeUnavailable), sent: "", pin: pin)
        #expect(!actions.contains { if case .copyToClipboard = $0 { return true } else { return false } })
        #expect(actions.last == .endLatch)
    }
}

@Suite struct EmacsLatchLispTests {
    @Test func insertNeverInterpolatesRawText() {
        let nasty = "\") (delete-file \"x\") (\"\n&-"
        let lisp = EmacsLatchLisp.insert(id: 3, text: nasty)
        #expect(!lisp.contains("delete-file"))
        #expect(lisp.contains(Data(nasty.utf8).base64EncodedString()))
        #expect(lisp.contains("susurro--latch-3"))
    }

    @Test func decodeReplies() {
        func reply(_ s: String) -> String { "-print " + EmacsServerProtocol.quote("\"\(s)\"\n") + "\n" }
        #expect(EmacsLatchLisp.decode(reply: reply("GONE")) == .gone)
        #expect(EmacsLatchLisp.decode(reply: reply("SKIP")) == .skip)
        #expect(EmacsLatchLisp.decode(reply: reply(Data("hé llo".utf8).base64EncodedString())) == .value("hé llo"))
        #expect(EmacsLatchLisp.decode(reply: nil) == .none)
        #expect(EmacsLatchLisp.decode(reply: "-error oops") == .none)
    }

    @Test func markerHasInsertionTypeTAndIsReleased() {
        #expect(EmacsLatchLisp.pin(id: 1).contains("copy-marker (window-point w) t"))
        #expect(EmacsLatchLisp.pin(id: 1).contains("minibufferp"))
        #expect(EmacsLatchLisp.release(id: 1).contains("set-marker susurro--latch-1 nil"))
    }
}

final class FakeLatchTarget: LatchTarget, @unchecked Sendable {
    let pin = LatchPin(method: .emacsServer, bundleID: "org.gnu.Emacs", appName: "Emacs",
                       documentName: "*scratch*", handle: "1")
    var text = "Hello"
    var alive = true
    var reachable = true
    var mangle = false
    var released = false
    func context() -> LatchBridgeReply {
        guard reachable else { return .unavailable }
        return alive ? .value(text) : .gone
    }
    func insert(_ s: String) -> LatchBridgeReply {
        guard reachable else { return .unavailable }
        guard alive else { return .gone }
        text += s
        return .value(mangle ? String(s.dropLast()) : s)
    }
    func release() { released = true }
}

@Suite struct LatchDeliverTests {
    @Test func deliversAndVerifies() {
        let t = FakeLatchTarget()
        #expect(LatchDelivery.contextFailure(t.context()) == nil)
        #expect(LatchDelivery.deliver(" world.", to: t) == .delivered)
        #expect(t.text == "Hello world.")
    }

    @Test func goneUnavailableAndMismatchFail() {
        let t = FakeLatchTarget()
        t.mangle = true
        #expect(LatchDelivery.deliver(" x", to: t) == .failed(.readBackMismatch))
        t.alive = false
        #expect(LatchDelivery.contextFailure(t.context()) == .failed(.targetGone))
        #expect(LatchDelivery.deliver(" y", to: t) == .failed(.targetGone))
        t.reachable = false
        #expect(LatchDelivery.deliver(" z", to: t) == .failed(.bridgeUnavailable))
    }
}
