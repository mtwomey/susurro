import Testing
@testable import SusurroCore

@Suite struct SpacingRuleTests {
    @Test func periodTriggersSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "done.") == true)
    }

    @Test func exclamationAndQuestionTriggerSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "really!") == true)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "really?") == true)
    }

    @Test func letterOrDigitDoesNotTriggerSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "hello") == false)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "item 3") == false)
    }

    @Test func commaDoesNotTriggerSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "wait,") == false)
    }

    @Test func closingQuoteAfterSentenceEnderTriggersSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "she said \"done.\"") == true)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "she asked \u{201C}really?\u{201D}") == true)
    }

    @Test func closingParenAfterSentenceEnderTriggersSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "(see above.)") == true)
    }

    @Test func closingWrapperWithoutSentenceEnderDoesNotTrigger() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "(see above)") == false)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "she said \"hello\"") == false)
    }

    @Test func trailingSpaceIsIgnoredNotDoubled() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "done. ") == true)
    }

    @Test func trailingNewlineIsIgnored() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "done.\n") == true)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "done.\n\n") == true)
    }

    @Test func onlyWhitespaceYieldsNoSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "   ") == false)
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: "") == false)
    }

    @Test func nilTailYieldsNoSpace() {
        #expect(SpacingRule.needsLeadingSpace(beforeCursor: nil) == false)
    }
}
