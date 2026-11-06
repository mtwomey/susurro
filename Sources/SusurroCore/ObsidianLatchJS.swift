import Foundation

/// JavaScript for the Obsidian latch bridge (BEA-691), run through the
/// official CLI (`obsidian eval code=…`). Pure, so it is unit-tested. The
/// snippets are fixed; the only parameters are a generated integer id and
/// the chunk text as a JSON string literal — raw text is never interpolated.
///
/// Position tracking: at pin time the leaf's CM6 `EditorView.update` is
/// wrapped once so every document change maps each pinned offset through
/// `ChangeSet.mapPos(pos, 1)`. That follows the user's concurrent edits and
/// advances past our own insert. Release removes the pin and, with the last
/// pin on that view, the wrapper.
///
/// Undo: no `isolateHistory` (not reachable from `eval`: `@codemirror/*`
/// isn't requirable there). CM6 groups changes < 500 ms apart; latched
/// chunks are cut at pauses, so each chunk is normally its own undo step.
public enum ObsidianLatchJS {
    public static let maxContext = 200

    /// JSON string literal for `text` (valid JavaScript).
    public static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())   // strip [ ]
    }

    public static func pin(id: Int) -> String {
        """
        (()=>{const l=app.workspace.activeLeaf;const v=l&&l.view;\
        if(!v||v.getViewType()!=='markdown'||!v.editor||!v.editor.cm||!v.file)return JSON.stringify({ok:false});\
        const ed=v.editor,cm=ed.cm;const S=(window.__susurroLatch=window.__susurroLatch||{});\
        S[\(id)]={leaf:l.id,path:v.file.path,pos:ed.posToOffset(ed.getCursor('to')),cm:cm};\
        if(!cm.__susurroWrapped){const orig=Object.getPrototypeOf(cm).update;\
        cm.update=function(trs){for(const tr of trs){if(!tr.docChanged)continue;\
        for(const k in S){if(S[k].cm===cm)S[k].pos=tr.changes.mapPos(S[k].pos,1);}}return orig.call(this,trs);};\
        cm.__susurroWrapped=true;}\
        return JSON.stringify({ok:true,name:v.file.basename,path:v.file.path});})()
        """
    }

    /// Shared prologue: resolve the pin or reply {gone:true}.
    private static func resolve(_ id: Int) -> String {
        """
        const st=(window.__susurroLatch||{})[\(id)];if(!st)return JSON.stringify({gone:true});\
        const l=app.workspace.getLeafById(st.leaf);const v=l&&l.view;\
        if(!v||!v.file||v.file.path!==st.path||!v.editor||v.editor.cm!==st.cm)return JSON.stringify({gone:true});\
        const ed=v.editor;const p=Math.min(st.pos,ed.getValue().length);\
        const ctx=ed.getRange(ed.offsetToPos(Math.max(0,p-\(maxContext))),ed.offsetToPos(p));
        """
    }

    public static func context(id: Int) -> String {
        "(()=>{\(resolve(id))return JSON.stringify({ctx:ctx});})()"
    }

    /// Insert at the pin; replies {ctx, back} (read-back of the inserted range).
    public static func insert(id: Int, text: String) -> String {
        """
        (()=>{\(resolve(id))const t=\(literal(text));ed.replaceRange(t,ed.offsetToPos(p));\
        if(st.pos!==p+t.length)st.pos=p+t.length;\
        const back=ed.getRange(ed.offsetToPos(p),ed.offsetToPos(p+t.length));\
        return JSON.stringify({ctx:ctx,back:back});})()
        """
    }

    public static func release(id: Int) -> String {
        """
        (()=>{const S=window.__susurroLatch||{};const st=S[\(id)];delete S[\(id)];\
        if(st&&st.cm&&!Object.values(S).some(x=>x.cm===st.cm)){delete st.cm.update;delete st.cm.__susurroWrapped;}\
        return JSON.stringify({ok:true});})()
        """
    }

    public struct Reply: Decodable, Equatable, Sendable {
        public var ok: Bool?
        public var gone: Bool?
        public var name: String?
        public var path: String?
        public var ctx: String?
        public var back: String?
    }

    /// Parses CLI output (`=> {json}`); nil when it isn't a reply.
    public static func decode(_ output: String) -> Reply? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: Data(output[start...end].utf8))
    }

    /// "1.14.5 (installer 1.13.7)" -> [1, 14, 5]: the app version, not the bundle's.
    public static func appVersion(_ output: String) -> [Int]? {
        guard let first = output.split(whereSeparator: { $0 == " " || $0 == "\n" }).first else { return nil }
        let parts = first.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    /// Full support or nothing: the lowest app version this bridge has been
    /// verified on (1.14.5, BEA-691 live test). Older versions are refused
    /// with the CLI pill until verified.
    public static let minimumVersion = [1, 14, 5]
    public static func supported(_ version: [Int]) -> Bool {
        version.lexicographicallyPrecedes(minimumVersion) == false
    }

    public static let cliOffPill = "Latching in Obsidian needs Settings → General → Command line interface"
}
