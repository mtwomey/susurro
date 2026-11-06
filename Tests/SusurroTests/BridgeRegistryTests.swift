import Foundation
import Testing
@testable import SusurroCore

private final class StubTarget: LatchTarget {
    let pin: LatchPin
    init(_ request: LatchPinRequest) {
        pin = LatchPin(method: BridgeID(rawValue: "stub"), bundleID: request.bundleID, appName: request.appName,
                       documentName: "doc", handle: String(request.token))
    }
    func context() -> LatchBridgeReply { .value("") }
    func insert(_ text: String) -> LatchBridgeReply { .value(text) }
    func release() {}
}

private struct StubBridge: LatchingBridge, ContextReadingBridge {
    var id = BridgeID(rawValue: "stub")
    var bundleIDs: Set<String> = ["com.example.Stub"]
    var name = "stub"
    var documentNoun = "page"
    var failure: BridgeError?
    var pill: String?
    func textBeforeCursor() -> String? { "ctx" }
    func pin(_ request: LatchPinRequest) throws(BridgeError) -> any LatchTarget {
        if let failure { throw failure }
        return StubTarget(request)
    }
    func refusalPill(for error: BridgeError) -> String? { pill }
}

@Suite struct BridgeRegistryTests {
    let request = LatchPinRequest(pid: 42, bundleID: "com.example.Stub", appName: "Stub", token: 7)
    let allow = LatchAllowlist(entries: [LatchCapability(bundleID: "com.example.Stub", method: BridgeID(rawValue: "stub"))])

    @Test func standardRegistryWiring() {
        let r = BridgeRegistry.standard
        #expect(r.contextReader(for: "org.gnu.Emacs")?.name == "emacs")
        #expect(r.contextReader(for: "md.obsidian") == nil)          // Obsidian context stays on AX
        #expect(r.contextReader(for: "com.apple.Safari") == nil)
        #expect(r.contextReader(for: nil) == nil)
        #expect(r.latchBridge(.emacsServer)?.documentNoun == "buffer")
        #expect(r.latchBridge(.obsidianCLI)?.documentNoun == "note")
        #expect(r.latchBridge(.axSelectedText)?.documentNoun == "document")
    }

    @Test func notAllowlistedIsTheGenericPill() {
        let r = LatchPolicy.engage(request, allowlist: LatchAllowlist(entries: []), registry: BridgeRegistry([StubBridge()]))
        guard case .failure(let refusal) = r else { Issue.record("engaged"); return }
        #expect(refusal == .notAllowlisted)
        #expect(refusal.pill(appName: "Stub") == "Latching isn't supported in Stub")
    }

    @Test func allowlistedButNotCompiledIn() {
        let r = LatchPolicy.engage(request, allowlist: allow, registry: BridgeRegistry([]))
        guard case .failure(let refusal) = r else { Issue.record("engaged"); return }
        #expect(refusal == .bridgeMissing(BridgeID(rawValue: "stub")))
        #expect(refusal.pill(appName: "Stub") == "Latching isn't supported in Stub")
    }

    @Test func bridgeFailureUsesTheBridgePillOrTheGenericOne() {
        var b = StubBridge(); b.failure = .notEnabled; b.pill = "Turn it on"
        guard case .failure(let r1) = LatchPolicy.engage(request, allowlist: allow, registry: BridgeRegistry([b])) else {
            Issue.record("engaged"); return
        }
        #expect(r1 == .bridgeFailed(.notEnabled, pill: "Turn it on"))
        #expect(r1.pill(appName: "Stub") == "Turn it on")
        b.failure = .noTarget; b.pill = nil
        guard case .failure(let r2) = LatchPolicy.engage(request, allowlist: allow, registry: BridgeRegistry([b])) else {
            Issue.record("engaged"); return
        }
        #expect(r2.pill(appName: "Stub") == "Latching isn't supported in Stub")
    }

    @Test func engagesAndPassesTheRequest() {
        guard case .success(let t) = LatchPolicy.engage(request, allowlist: allow, registry: BridgeRegistry([StubBridge()])) else {
            Issue.record("refused"); return
        }
        #expect(t.pin.handle == "7" && t.pin.appName == "Stub")
    }

    @Test func obsidianPillsUnchanged() {
        let o = ObsidianBridge()
        #expect(o.refusalPill(for: .notEnabled) == "Latching in Obsidian needs Settings → General → Command line interface")
        #expect(o.refusalPill(for: .unsupportedVersion(found: [1, 13], minimum: [1, 14, 5])) == "Latching needs Obsidian 1.14.5 or later")
        #expect(o.refusalPill(for: .noTarget) == nil)
    }

    @Test func noCentralSwitchLeft() throws {
        // The app target must not know individual bridges (docs/BRIDGES.md §5).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appDir = root.appendingPathComponent("Sources/Susurro")
        let files = try FileManager.default.contentsOfDirectory(atPath: appDir.path).filter { $0.hasSuffix(".swift") }
        for file in files {
            let text = try String(contentsOf: appDir.appendingPathComponent(file), encoding: .utf8)
            for banned in ["EmacsBridge", "ObsidianBridge", "AXSelectedTextBridge", ".emacsServer", ".obsidianCLI", "ObsidianLatchJS", "EmacsLatchLisp"] {
                #expect(!text.contains(banned), "\(file) mentions \(banned)")
            }
        }
    }
}
