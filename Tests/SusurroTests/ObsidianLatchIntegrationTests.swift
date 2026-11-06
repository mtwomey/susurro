import Foundation
import Testing
@testable import SusurroCore

/// Live check of the Obsidian latch JS through the official CLI, on a
/// throwaway note opened in a background tab (deleted afterwards). Obsidian
/// is never brought forward; the user's active leaf is restored at once.
/// Opt-in: SUSURRO_OBSIDIAN_IT=1 swift test --filter ObsidianLatchIntegration
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUSURRO_OBSIDIAN_IT"] == "1"))
struct ObsidianLatchIntegrationTests {
    static let note = "susurro-latch-it-scratch.md"

    /// Shipping transport (ProcessRunner), stdout only.
    func eval(_ js: String) -> String {
        ProcessRunner().run("/usr/local/bin/obsidian", ["eval", "code=" + js], timeout: 5)?.stdout ?? ""
    }

    @Test func pinInsertMapsThroughEditsAndDetectsClose() {
        let id = LatchToken.make(nonce: 333, counter: 1)
        // A pin left by a "crashed" launch (other nonce): pin must sweep it.
        _ = eval("(()=>{(window.__susurroLatch=window.__susurroLatch||{})['111000001']={cm:null};return '{}';})()")
        // Scratch note in a background tab; pin it with the real pin snippet
        // while it is briefly the active leaf (no focus), then restore.
        let setup = eval("""
        (async()=>{const prev=app.workspace.activeLeaf;const f=await app.vault.create('\(Self.note)','Hello');\
        const l=app.workspace.getLeaf('tab');await l.openFile(f,{active:false});\
        app.workspace.setActiveLeaf(l,{focus:false});l.view.editor.setCursor(l.view.editor.offsetToPos(5));\
        const r=\(ObsidianLatchJS.pin(id: id));if(prev)app.workspace.setActiveLeaf(prev,{focus:false});\
        window.__susurroIT=l.id;return r;})()
        """)
        let pinned = ObsidianLatchJS.decode(setup)
        #expect(pinned?.ok == true, "setup: \(setup)")
        #expect(pinned?.name == "susurro-latch-it-scratch")
        let keys = eval("(()=>JSON.stringify({ctx:Object.keys(window.__susurroLatch||{}).join(',')}))()")
        #expect(ObsidianLatchJS.decode(keys)?.ctx == String(id))
        defer {
            _ = eval(ObsidianLatchJS.release(id: id))
            _ = eval("""
            (async()=>{const l=app.workspace.getLeafById(window.__susurroIT);if(l)l.detach();\
            const f=app.vault.getAbstractFileByPath('\(Self.note)');if(f)await app.vault.delete(f);\
            delete window.__susurroIT;return JSON.stringify({ok:!app.vault.getAbstractFileByPath('\(Self.note)')});})()
            """)
        }
        #expect(ObsidianLatchJS.decode(eval(ObsidianLatchJS.context(id: id)))?.ctx == "Hello")
        let first = ObsidianLatchJS.decode(eval(ObsidianLatchJS.insert(id: id, text: " world.")))
        #expect(first?.back == " world." && first?.ctx == "Hello")
        // Concurrent user edit before the pin: the pin must follow it.
        _ = eval("(()=>{const ed=app.workspace.getLeafById(window.__susurroIT).view.editor;ed.replaceRange('Say: ',{line:0,ch:0});return '{}';})()")
        let tricky = " Ünïcode \"q\" `${x}` \\ end"
        let second = ObsidianLatchJS.decode(eval(ObsidianLatchJS.insert(id: id, text: tricky)))
        #expect(second?.back == tricky)
        let value = eval("(()=>JSON.stringify({ctx:app.workspace.getLeafById(window.__susurroIT).view.editor.getValue()}))()")
        #expect(ObsidianLatchJS.decode(value)?.ctx == "Say: Hello world." + tricky)
        // Note closed: gone, nothing written.
        _ = eval("(()=>{app.workspace.getLeafById(window.__susurroIT).detach();return '{}';})()")
        #expect(ObsidianLatchJS.decode(eval(ObsidianLatchJS.insert(id: id, text: "lost")))?.gone == true)
    }
}
