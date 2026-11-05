import Foundation
import Testing
@testable import SusurroCore

/// BEA-673: empty-field shapes recorded from real AX reads (no user text).
/// Chromium reports CSS `::before { content: attr(data-placeholder) }` text as
/// the AXValue of an empty contenteditable, with AXPlaceholderValue nil; the
/// reader passes such generated (non-editable) leaf text in `placeholders`.
/// Shapes from the Hermes desktop composer (Electron) and a Chrome page
/// reproducing the Hermes, Quill and ProseMirror/Tiptap placeholder patterns.
@Suite struct EmptyFieldEchoTests {
    let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)

    func resolve(_ snap: FieldSnapshot) -> InsertContext {
        InsertContext.resolve(snapshot: snap, memoryTail: nil, pid: 1, bundleID: "any.app",
                              engine: nil, secureInput: false).0
    }

    func area(_ value: String, caret: Int, placeholders: [String] = []) -> FieldSnapshot {
        FieldSnapshot(value: value, selection: NSRange(location: caret, length: 0),
                      role: "AXTextArea", placeholders: placeholders)
    }

    @Test func emptyComposerEchoesGeneratedPlaceholder() {
        // Hermes: value == generated leaf, valueLen=20.
        let ctx = resolve(area("What's on your mind?", caret: 20, placeholders: ["What's on your mind?"]))
        #expect(ctx.before == "")
        #expect(stage.apply("Hello there.", ctx) == "Hello there.")
    }

    @Test func typedThenDeletedKeepsScaffoldingNewline() {
        // Recorded in text-handling.log: valueLen=23 caret=22 / valueLen=21 caret=20.
        for p in ["Describe what you need", "What's on your mind?"] {
            let len = (p as NSString).length
            let ctx = resolve(area(p + "\n", caret: len, placeholders: [p]))
            #expect(ctx.before == "")
            #expect(stage.apply("hello there", ctx) == "Hello there")
        }
    }

    @Test func quillAndProseMirrorEmptyShapes() {
        // Quill: .ql-blank::before + <p><br></p>; ProseMirror: p.is-empty::before.
        #expect(resolve(area("Message #general\n", caret: 16, placeholders: ["Message #general"])).before == "")
        #expect(resolve(area("Type / for commands\n", caret: 19, placeholders: ["Type / for commands"])).before == "")
    }

    @Test func axPlaceholderValueEchoIsEmpty() {
        #expect(resolve(area("Search", caret: 6, placeholders: ["Search"])).before == "")
    }

    @Test func zeroWidthAndNewlineOnlyFieldsAreEmpty() {
        #expect(resolve(area("\u{200B}", caret: 1)).before == "")
        #expect(resolve(area("\n", caret: 0)).before == "")
        #expect(resolve(area("\u{FEFF}\n", caret: 1)).before == "")
    }

    @Test func realTextIsUntouched() {
        // Real text: no generated leaves, so nothing to match; space still added.
        let ctx = resolve(area("Fix the build", caret: 13))
        #expect(ctx.before == "Fix the build")
        #expect(stage.apply("now", ctx) == " now")
        // Text that merely contains a placeholder is real text.
        let c2 = resolve(area("Ask anything you like", caret: 21, placeholders: ["Ask anything"]))
        #expect(c2.before == "Ask anything you like")
        // A native field with text and a placeholder attribute: unchanged.
        #expect(resolve(area("Dear Kim,", caret: 9, placeholders: ["Message"])).before == "Dear Kim,")
    }

    @Test func alreadyEmptyShapesUnchanged() {
        // Zen/Slack empty shapes from the log, and aria-placeholder/textarea/input
        // placeholders (Chrome: value "" with AXPlaceholderValue set).
        #expect(resolve(area("", caret: 0, placeholders: ["Write a reply"])).before == "")
        #expect(resolve(area("\n", caret: 0)).before == "")
    }

    @Test func sanitizedMarksEmptyEchoAndIsIdempotent() {
        let s = area("Message #general\n", caret: 16, placeholders: ["Message #general"]).sanitized
        #expect(s.value == "" && s.emptyEcho && s.detail.contains("emptyEcho"))
        #expect(s.sanitized == s)
    }
}
