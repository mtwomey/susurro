import Foundation
import Testing
@testable import SusurroCore

/// BEA-673 (Warp): a terminal-shaped field exposes its whole buffer as AXValue
/// with no caret. With the input line empty, Warp's value ends in its prompt
/// context line, not in Susurro's last text, so the remembered text must not
/// be used as "text before the cursor". Shapes only; no real buffer content.
@Suite struct StaleMemoryTests {
    let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)
    func resolve(_ value: String?, memory: String?) -> (InsertContext, String) {
        InsertContext.resolve(snapshot: FieldSnapshot(value: value, role: "AXTextArea"), memoryTail: memory,
                              pid: 1, bundleID: nil, engine: nil, secureInput: false)
    }
    let history = "$ make test\nok 12 tests\n"
    let prompt = "user ~/repo git:(main) • +1 -0 "

    @Test func clearedInputAfterDictationGetsNoSpace() {
        // Recorded: anchoredValue.end, then the input cleared -> memory -> stray space.
        let (c, p) = resolve(history + prompt, memory: "check the build")
        #expect(p == "none")
        #expect(stage.apply("run it again", c) == "Run it again")
    }

    @Test func commandRunWithDictatedTextInHistoryGetsNoSpace() {
        let (c, p) = resolve(history + "$ git status please\nclean\n" + "$ git status please\nclean\n" + prompt,
                             memory: "git status please")
        #expect(p == "none")
        #expect(stage.apply("next", c) == "Next")
    }

    @Test func continuationOnTheInputLineStillGetsSpace() {
        let (c, p) = resolve(history + prompt + "check the build", memory: "check the build")
        #expect(p == "anchoredValue.end")
        #expect(stage.apply("now", c) == " now")
    }

    @Test func noReadableValueStillUsesMemory() {
        let (c, p) = resolve(nil, memory: "check the build")
        #expect(p == "memory")
        #expect(stage.apply("now", c) == " now")
    }
}

/// Board test 20:01-20:02Z (Warp): after Enter on empty prompts, or after
/// backspacing over the whole line, the mid-buffer anchor found Susurro's text
/// in the history -> stray space and a lower-case "continuation".
@Suite struct WarpHistoryAnchorTests {
    let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)
    let prompt = "user ~/repo git:(main) • +1 -0 "
    func resolve(_ value: String, _ memory: RememberedInsertion) -> (InsertContext, String) {
        InsertContext.resolve(snapshot: FieldSnapshot(value: value, role: "AXTextArea"), memory: memory,
                              pid: 1, bundleID: nil, engine: nil, secureInput: false)
    }
    /// What Susurro records after typing `typed` at the end of `value`.
    func afterTyping(_ typed: String, into value: String) -> RememberedInsertion {
        let n = (value + typed as NSString).length
        return RememberedInsertion(tail: typed, position: ValuePosition(caretOffset: n, valueLength: n))
    }

    @Test func commandRunOnceWithoutPositionGetsNoSpace() {
        let v = "$ make\nok\n$ git status please\nclean\n" + prompt
        let (c, p) = InsertContext.resolve(snapshot: FieldSnapshot(value: v, role: "AXTextArea"),
                                           memoryTail: "git status please", pid: 1, bundleID: nil,
                                           engine: nil, secureInput: false)
        #expect(p == "none")
        #expect(stage.apply("next one", c) == "Next one")
    }

    @Test func enterOnEmptyPromptsThenDictateGetsNoSpace() {
        let start = "$ make\nok\n" + prompt
        let memory = afterTyping("check the build", into: start)
        // Enter ran it, then Enter twice more on empty prompts.
        let now = start + "check the build\nok\n" + prompt + "\n" + prompt + "\n" + prompt
        let (c, p) = resolve(now, memory)
        #expect(p == "none")
        #expect(stage.apply("run it again", c) == "Run it again")
    }

    @Test func backspacedWholeLineGetsCapitalAndNoSpace() {
        // The text survives once in the history (an earlier run), the input line was cleared.
        let start = "$ check the build\nok\n" + prompt
        let memory = afterTyping("check the build", into: start)
        let (c, p) = resolve(start, memory)
        #expect(p == "none")
        #expect(stage.apply("new sentence", c) == "New sentence")
    }

    @Test func continuationOnTheLineStillSpaced() {
        let start = "$ make\nok\n" + prompt
        let memory = afterTyping("check the build", into: start)
        let (c, p) = resolve(start + "check the build", memory)
        #expect(p == "anchoredValue.end")
        #expect(stage.apply("now", c) == " now")
    }
}
