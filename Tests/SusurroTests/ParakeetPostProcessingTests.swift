import Foundation
import Testing
@testable import SusurroCore

/// Goldens for Parakeet-shaped input (BEA-636). Parakeet v2 emits cased,
/// punctuated text and keeps spoken triggers literal, often with its own
/// punctuation glued on ("comma,", "question mark?"). Raw inputs marked
/// "real" are verbatim Parakeet v2 output from `susurro-cli --post` on
/// fixtures/clip3.wav or `say`-generated dictation (2026-11-04); the rest are
/// the shapes those runs imply. Each pair asserts the same final text whisper
/// gets for the same dictation, so verbal punctuation behaves the same on
/// both engines.
@Suite struct ParakeetPostProcessingTests {
    private func makeProcessor() -> PostProcessor {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("susurro-tests-\(UUID().uuidString)/rules.json")
        return PostProcessor(userRulesURL: missing) // bundled defaults
    }

    static let cases: [(input: String, expected: String)] = [
        // real
        ("Add a comment that says quote this is a temporary workaround end quote, comma, then file a ticket, period.",
         "Add a comment that says \"this is a temporary workaround\", then file a ticket."),
        ("Is the build ready question mark", "Is the build ready?"),
        ("This is great exclamation point", "This is great!"),
        ("Hello comma, how are you today question mark", "Hello, how are you today?"),
        ("Add a note colon by milk and eggs period", "Add a note: by milk and eggs."),
        ("First line, new line, second line", "First line\nsecond line"),
        ("Use a backslash to escape it", "Use a \\ to escape it"),
        ("She said, quote hello there end quote and left", "She said \"hello there\" and left"),
        ("List the items semicolon, then continue period", "List the items; then continue."),
        ("Dear John Comma, new line, thanks for the update period",
         "Dear John,\nthanks for the update."),
        // shapes: the engine's own punctuation after a trigger must not double up
        ("Is the build ready question mark?", "Is the build ready?"),
        ("This is great exclamation point!", "This is great!"),
        ("Then file a ticket period.", "Then file a ticket."),
        ("Ends here period?", "Ends here."),
        ("Wait comma, what question mark?", "Wait, what?"),
        // shapes: the engine's sentence split at a mid-sentence trigger
        ("Add a note colon. Buy milk.", "Add a note: buy milk."),
        ("Hello comma. How are you question mark?", "Hello, how are you?"),
        ("First semicolon. Second.", "First; second."),
        ("Well comma. I think so.", "Well, I think so."),          // "I" stays
        ("Ship it comma. NASA said.", "Ship it, NASA said."),       // acronym stays
        // a real "?" before "new line" survives
        ("Are you there? New line. Yes.", "Are you there?\nYes."),
        // no triggers: Parakeet's own formatting passes through untouched
        ("The meeting is at 3:30 p.m. on January 22nd.", "The meeting is at 3:30 p.m. on January 22nd."),
    ]

    @Test(arguments: cases.indices)
    func parakeetShaped(index: Int) {
        let (input, expected) = Self.cases[index]
        #expect(makeProcessor().process(input) == expected)
    }

    @Test func noDoubledPunctuationOrSpaces() {
        for (input, _) in Self.cases {
            let out = makeProcessor().process(input)
            #expect(!out.contains("  "), "double space in \(out.debugDescription)")
            #expect(out.range(of: "[,.?!;:]{2}", options: .regularExpression) == nil
                    || out.contains("p.m."), "doubled punctuation in \(out.debugDescription)")
        }
    }

    // Whisper small.en (real, `say` dictation): renders the spoken quote as
    // quote marks *and* keeps the words — previously `" "hello there" "`.
    @Test func whisperQuotedTriggersDoNotDoubleQuotes() {
        #expect(makeProcessor().process("She said, \"quote hello there end quote\" and left.")
                == "She said, \"hello there\" and left.")
    }

    @Test func genuineClosingQuoteBeforeCommaSurvives() {
        #expect(makeProcessor().process("he said \"hi\" comma then left")
                == "He said \"hi\", then left")
    }
}

@Suite struct EngineAwareFilterTests {
    @Test func parakeetKeepsBrackets() {
        #expect(TranscriptFilter.stripHallucinations("Use arr [0] here", engine: .parakeet)
                == "Use arr [0] here")
    }

    @Test func parakeetStillNormalisesWhitespace() {
        #expect(TranscriptFilter.stripHallucinations("  Hello   world. ", engine: .parakeet)
                == "Hello world.")
    }

    @Test func whisperDefaultStillStripsTokens() {
        #expect(TranscriptFilter.stripHallucinations("[BLANK_AUDIO]") == "")
        #expect(TranscriptFilter.stripHallucinations("hi [MUSIC] there", engine: .whisper) == "hi there")
    }
}
