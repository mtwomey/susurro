import Foundation
import Testing
@testable import SusurroCore

/// BEA-673: empty-field shapes recorded from real AX reads (no user text).
/// Hermes desktop composer: a Chromium contenteditable whose placeholder is
/// CSS `::before { content: attr(data-placeholder) }`; AXPlaceholderValue nil.
@Suite struct EmptyFieldEchoTests {
    let hermes = "com.nousresearch.hermes"
    let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)

    func resolve(_ snap: FieldSnapshot, bundle: String? = nil) -> InsertContext {
        InsertContext.resolve(snapshot: snap, memoryTail: nil, pid: 1, bundleID: bundle,
                                engine: nil, secureInput: false).0
    }

    func area(_ value: String, caret: Int, placeholders: [String]) -> FieldSnapshot {
        FieldSnapshot(value: value, selection: NSRange(location: caret, length: 0),
                      role: "AXTextArea", placeholders: placeholders)
    }

    @Test func hermesEmptyComposerEchoesPlaceholder() {
        // Recorded: valueLen=20 caret=20 (unfocused read), value == a placeholder.
        let ph = GeneratedPlaceholders.placeholders(for: hermes)
        let ctx = resolve(area("What's on your mind?", caret: 20, placeholders: ph), bundle: hermes)
        #expect(ctx.before == "")
        #expect(stage.apply("Hello there.", ctx) == "Hello there.")
    }

    @Test func hermesTypedThenDeletedKeepsScaffoldingNewline() {
        // Recorded in text-handling.log: valueLen=23 caret=22 / valueLen=21 caret=20.
        let ph = GeneratedPlaceholders.placeholders(for: hermes)
        for p in ["Describe what you need", "What's on your mind?"] {
            let len = (p as NSString).length
            let ctx = resolve(area(p + "\n", caret: len, placeholders: ph), bundle: hermes)
            #expect(ctx.before == "")
            #expect(stage.apply("hello there", ctx) == "Hello there")
        }
    }

    @Test func axPlaceholderValueEchoIsEmpty() {
        let ctx = resolve(area("Search", caret: 6, placeholders: ["Search"]))
        #expect(ctx.before == "")
    }

    @Test func zeroWidthAndNewlineOnlyFieldsAreEmpty() {
        #expect(resolve(area("\u{200B}", caret: 1, placeholders: [])).before == "")
        #expect(resolve(area("\n", caret: 0, placeholders: [])).before == "")
        #expect(resolve(area("\u{FEFF}\n", caret: 1, placeholders: [])).before == "")
    }

    @Test func realTextIsUntouched() {
        // Hermes with real text: caret after it, space still added.
        let ph = GeneratedPlaceholders.placeholders(for: hermes)
        let ctx = resolve(area("Fix the build", caret: 13, placeholders: ph), bundle: hermes)
        #expect(ctx.before == "Fix the build")
        #expect(stage.apply("now", ctx) == " now")
        // Text that merely contains a placeholder is real text.
        let c2 = resolve(area("Ask anything you like", caret: 21, placeholders: ph), bundle: hermes)
        #expect(c2.before == "Ask anything you like")
    }

    @Test func otherAppsGetNoGeneratedPlaceholders() {
        for b in ["app.zen-browser.zen", "com.tinyspeck.slackmacgap", "com.apple.Notes",
                  "com.apple.TextEdit", "com.apple.Terminal", "com.microsoft.VSCode", nil] {
            #expect(GeneratedPlaceholders.placeholders(for: b).isEmpty)
        }
        // Slack/Zen empty shapes from the log still resolve as before.
        #expect(resolve(area("\n", caret: 0, placeholders: [])).before == "")
        #expect(resolve(area("", caret: 0, placeholders: [])).before == "")
        // Native field with text: unchanged.
        #expect(resolve(area("Dear Kim,", caret: 9, placeholders: ["Message"])).before == "Dear Kim,")
    }
}
