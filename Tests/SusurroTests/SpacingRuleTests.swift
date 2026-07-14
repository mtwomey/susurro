import Testing
@testable import SusurroCore

@Suite struct SpacingRuleTests {
    @Test func endsInLetterTriggersSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "hello") == true)
    }

    @Test func endsInDigitTriggersSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "item 3") == true)
    }

    @Test func endsInCommaTriggersSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "wait,") == true)
    }

    @Test func endsInSentencePunctuationTriggersSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "done.") == true)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "really!") == true)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "really?") == true)
    }

    @Test func endsInClosingQuoteOrParenTriggersSpace() {
        // No longer conditioned on what's behind the wrapper — resuming a
        // dictation always wants a word-boundary space.
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "she said \"hello\"") == true)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "(see above)") == true)
    }

    @Test func trailingSpaceDoesNotDoubleUp() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "done. ") == false)
    }

    @Test func trailingNewlineDoesNotTrigger() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "done.\n") == false)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "line one\n\n") == false)
    }

    @Test func onlyWhitespaceYieldsNoSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "   ") == false)
    }

    @Test func emptyTailYieldsNoSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "") == false)
    }

    @Test func nilTailYieldsNoSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: nil) == false)
    }
}
