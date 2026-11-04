import Testing
@testable import SusurroCore

@Suite struct ParakeetNumberRulesTests {
    @Test(arguments: [
        ("Can you call me at nine forty five AM to morrow?", "Can you call me at 9:45 a.m. to morrow?"),
        ("The meeting is at three thirty PM on january twenty second.", "The meeting is at 3:30 p.m. on January 22nd."),
        ("Set a reminder for eleven AM on december first.", "Set a reminder for 11 a.m. on December 1st."),
        ("Set a reminder for 11 A.M. on December 1st.", "Set a reminder for 11 a.m. on December 1st."),
        ("Rent goes up by three per cent, starting on April first.", "Rent goes up by 3%, starting on April 1st."),
        ("Revenue grew eighteen percent to 4.2 million.", "Revenue grew 18% to 4.2 million."),
        ("The invoice is due on march 3rd.", "The invoice is due on March 3rd."),
        ("Our flight leaves at six fifteen A.M. on Friday.", "Our flight leaves at 6:15 a.m. on Friday."),
        ("See you on May first.", "See you on May 1st."),
    ])
    func rewritesUnambiguousSpans(input: String, expected: String) {
        #expect(ParakeetNumberRules.apply(input) == expected)
    }

    @Test(arguments: [
        "I have one of the best ideas, and no one came.",
        "We may first need to check.",
        "Call me at nine.",
        "She came second in March.",
        "The meeting is at 3:30 p.m. on January 22nd.",
        "Revenue grew 18% to 4.2 million last quarter.",
        "The invoice for $1,250 is due on March 3rd.",
        "I'll be in Chicago from the fifth to the ninth of June.",
    ])
    func leavesOrdinarySpeechAndFormattedTextAlone(input: String) {
        #expect(ParakeetNumberRules.apply(input) == input)
    }
}
