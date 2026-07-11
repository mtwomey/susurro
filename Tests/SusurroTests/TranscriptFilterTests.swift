import Testing
@testable import SusurroCore

@Suite struct TranscriptFilterTests {
    @Test func silenceHallucinationBecomesEmpty() {
        #expect(TranscriptFilter.stripHallucinations("[BLANK_AUDIO]") == "")
        #expect(TranscriptFilter.stripHallucinations(" [MUSIC PLAYING] ") == "")
    }

    @Test func embeddedTokenRemoved() {
        #expect(TranscriptFilter.stripHallucinations("hello [inaudible] world")
                == "hello world")
    }

    @Test func normalTextUntouched() {
        #expect(TranscriptFilter.stripHallucinations("Just a normal sentence.")
                == "Just a normal sentence.")
    }

    @Test func parenthesesPreserved() {
        #expect(TranscriptFilter.stripHallucinations("call the function (with retries) now")
                == "call the function (with retries) now")
    }
}
