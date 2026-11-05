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

/// Known limit (documented, not fixed here): a dictated command that ran once
/// appears once in the history, and the mid-buffer anchor (built for editors
/// without a caret) still places the cursor after it.
@Suite struct StaleMemoryKnownLimits {
    @Test func singleRunCommandStillAnchorsMidBuffer() {
        let v = "$ make\nok\n$ git status please\nclean\nuser ~/repo git:(main) "
        let (_, p) = InsertContext.resolve(snapshot: FieldSnapshot(value: v, role: "AXTextArea"),
                                           memoryTail: "git status please", pid: 1, bundleID: nil,
                                           engine: nil, secureInput: false)
        #expect(p == "anchoredValue.interior")
    }
}
