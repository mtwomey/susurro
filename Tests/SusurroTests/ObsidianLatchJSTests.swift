import Foundation
import Testing
@testable import SusurroCore

@Suite struct ObsidianLatchJSTests {
    @Test func textIsJSONEscapedNeverRaw() {
        let nasty = "\"); app.vault.delete(x); (\"\n\u{2028}`${1}`"
        let js = ObsidianLatchJS.insert(id: 7, text: nasty)
        let lit = ObsidianLatchJS.literal(nasty)
        // The text is exactly one JSON string token in a fixed slot.
        #expect(js.contains("const t=\(lit);ed.replaceRange"))
        #expect(lit.hasPrefix("\"") && lit.hasSuffix("\""))
        let back = try? JSONSerialization.jsonObject(with: Data(lit.utf8), options: [.fragmentsAllowed]) as? String
        #expect(back == nasty)
    }

    @Test func decodeReplies() {
        #expect(ObsidianLatchJS.decode("=> {\"gone\":true}")?.gone == true)
        #expect(ObsidianLatchJS.decode("=> {\"ctx\":\"a\",\"back\":\" b\"}") == .init(ctx: "a", back: " b"))
        #expect(ObsidianLatchJS.decode("Error: CLI disabled") == nil)
    }

    @Test func versionGateUsesAppVersion() {
        #expect(ObsidianLatchJS.appVersion("1.14.5 (installer 1.13.7)") == [1, 14, 5])
        #expect(ObsidianLatchJS.supported([1, 14, 5]))
        #expect(ObsidianLatchJS.supported([1, 15]))
        #expect(!ObsidianLatchJS.supported([1, 14, 4]))
        #expect(ObsidianLatchJS.appVersion("") == nil)
    }

    @Test func pinWrapsUpdateOnceAndReleaseUnwraps() {
        let pin = ObsidianLatchJS.pin(id: 1)
        #expect(pin.contains("if(!cm.__susurroWrapped)") && pin.contains("mapPos(S[k].pos,1)"))
        #expect(pin.contains("getViewType()!=='markdown'"))
        #expect(ObsidianLatchJS.release(id: 1).contains("delete st.cm.update"))
    }
}

extension ObsidianLatchJS.Reply {
    init(ctx: String?, back: String?) { self.init(ok: nil, gone: nil, name: nil, path: nil, ctx: ctx, back: back) }
}
