import Testing
@testable import SusurroCore

struct HandsFreeJoinTests {
    // MARK: holdMark

    @Test func holdsFinalMark() {
        #expect(HandsFreeJoin.holdMark("So I was thinking that we should probably.") == ("So I was thinking that we should probably", "."))
        #expect(HandsFreeJoin.holdMark("Are you coming? ") == ("Are you coming", "?"))
        #expect(HandsFreeJoin.holdMark("Great!") == ("Great", "!"))
    }

    @Test func noMarkOrEllipsisIsNotHeld() {
        #expect(HandsFreeJoin.holdMark("no mark here") == ("no mark here", nil))
        #expect(HandsFreeJoin.holdMark("Wait...") == ("Wait...", nil))
        #expect(HandsFreeJoin.holdMark(".") == (".", nil))
        #expect(HandsFreeJoin.holdMark("Mid. sentence, then text") == ("Mid. sentence, then text", nil))
    }

    // MARK: decide

    @Test func continuationWhenJoinHasNoMark() {
        let d = HandsFreeJoin.decide(previousBody: "So I was thinking that we should probably",
                                     jointText: "So, I was thinking that we should probably move the deploy to Thursday.")
        #expect(d == .continuation)
    }

    @Test func breakWhenJoinHasMark() {
        let d = HandsFreeJoin.decide(previousBody: "Yes, that works for me",
                                     jointText: "Yes, that works for me. Send it to the team tomorrow morning.")
        #expect(d == .sentenceBreak)
        #expect(HandsFreeJoin.decide(previousBody: "Are you free", jointText: "are you free? I need help") == .sentenceBreak)
    }

    @Test func toleratesTailStartingMidWord() {
        // Joint clip began inside "thinking".
        let d = HandsFreeJoin.decide(previousBody: "I was thinking",
                                     jointText: "king, we should go now.")
        #expect(d == .continuation)
        #expect(HandsFreeJoin.decide(previousBody: "we should probably",
                                     jointText: "bably move it.") == .continuation)
    }

    @Test func fallsBackToFewerWords() {
        // The joint transcript changed an earlier word; the last two still match.
        let d = HandsFreeJoin.decide(previousBody: "the deploy to Thursday",
                                     jointText: "a deploy to Thursday. Then we ship.")
        #expect(d == .sentenceBreak)
    }

    @Test func unmatchedWhenEndingNotFound() {
        #expect(HandsFreeJoin.decide(previousBody: "completely different words",
                                     jointText: "nothing in common here.") == .unmatched)
        #expect(HandsFreeJoin.decide(previousBody: "", jointText: "x") == .unmatched)
        // A's ending is the last thing in the joint text: no evidence about B.
        #expect(HandsFreeJoin.decide(previousBody: "we should go", jointText: "we should go.") == .unmatched)
    }

    @Test func caseAndPunctuationInsensitiveMatching() {
        #expect(HandsFreeJoin.decide(previousBody: "Meet at 3:30 p.m",
                                     jointText: "meet at 3:30 p.m. Bring the slides.") == .sentenceBreak)
    }

    @Test func abbreviationBeforeLowercaseIsContinuation() {
        #expect(HandsFreeJoin.decide(previousBody: "The meeting is at 3:30 p.m",
                                     jointText: "The meeting is at 3:30 p.m. on January 22nd.") == .continuation)
    }

    @Test func cursorMovedFallback() {
        #expect(HandsFreeJoin.isInPlace(before: nil, previousBody: "we should probably"))
        #expect(HandsFreeJoin.isInPlace(before: "Hi. So we should probably", previousBody: "we should probably"))
        #expect(HandsFreeJoin.isInPlace(before: "so we should Probably ", previousBody: "we should probably"))
        #expect(!HandsFreeJoin.isInPlace(before: "Dear Sam,", previousBody: "we should probably"))
        #expect(!HandsFreeJoin.isInPlace(before: "", previousBody: "we should probably"))
    }

    @Test func trimsLongLeadingPause() {
        // 15 s of silence before speech at 16 kHz: keep 1.5 s of lead-in.
        #expect(HandsFreeJoin.trimmedStart(chunkStart: 1000, firstSpeech: 1000 + 240_000) == 1000 + 240_000 - 24_000)
        // Ordinary pause (2.5 s lead-in): untouched.
        #expect(HandsFreeJoin.trimmedStart(chunkStart: 1000, firstSpeech: 1000 + 40_000) == 1000)
        #expect(HandsFreeJoin.trimmedStart(chunkStart: 1000, firstSpeech: nil) == 1000)
    }

    // MARK: joined

    @Test func joinedText() {
        #expect(HandsFreeJoin.joined(mark: ".", decision: .sentenceBreak, next: "Send it to the team") == ". Send it to the team")
        #expect(HandsFreeJoin.joined(mark: ".", decision: .unmatched, next: "Send it") == ". Send it")
        #expect(HandsFreeJoin.joined(mark: ".", decision: .continuation, next: "Move the deploy") == " move the deploy")
        #expect(HandsFreeJoin.joined(mark: "?", decision: .continuation, next: "I think so") == " I think so")
        #expect(HandsFreeJoin.joined(mark: ".", decision: .continuation, next: "NASA said so") == " NASA said so")
        #expect(HandsFreeJoin.joined(mark: ".", decision: .continuation, next: "I'm going") == " I'm going")
    }

    @Test func wordsNeverChange() {
        // Only boundary punctuation and first-letter case may differ.
        let next = "Move the deploy to Thursday"
        for d in [HandsFreeJoin.Decision.continuation, .sentenceBreak, .unmatched] {
            let out = HandsFreeJoin.joined(mark: ".", decision: d, next: next)
            let words = out.split(separator: " ").map { $0.lowercased().filter(\.isLetter) }.filter { !$0.isEmpty }
            #expect(words == next.lowercased().split(separator: " ").map(String.init))
        }
    }

    // MARK: jointClip

    @Test func jointClipUsesSpeechTailRealPauseAndB() {
        let sr = 100 // tiny rate for readable indices
        let a = [Float](repeating: 1, count: 500) + [Float](repeating: 0, count: 50)  // speech 0..<500, silence after
        let b = [Float](repeating: 0, count: 50) + [Float](repeating: 2, count: 200)
        let clip = HandsFreeJoin.jointClip(a: a, aLastSpeechEnd: 500, b: b, bFirstSpeechStart: 50,
                                           sampleRate: sr, tailSeconds: 3, maxPause: 2)
        #expect(clip.count == 300 + 100 + 200)
        #expect(clip.prefix(300).allSatisfy { $0 == 1 })
        #expect(clip[300..<400].allSatisfy { $0 == 0 })
        #expect(clip.suffix(200).allSatisfy { $0 == 2 })
    }

    @Test func jointClipCapsLongPause() {
        let sr = 100
        let a = [Float](repeating: 1, count: 100) + [Float](repeating: 0, count: 300)
        let b = [Float](repeating: 0, count: 300) + [Float](repeating: 2, count: 10)
        let clip = HandsFreeJoin.jointClip(a: a, aLastSpeechEnd: 100, b: b, bFirstSpeechStart: 300,
                                           sampleRate: sr, maxPause: 2)
        #expect(clip.count == 100 + 200 + 10)
    }

    // MARK: HeldMarkJoiner state machine

    @Test func firstChunkIsFreshAndHoldsMark() {
        var j = HeldMarkJoiner()
        #expect(j.accept("So I was thinking that we should probably.", pid: 1) == .fresh(text: "So I was thinking that we should probably"))
        #expect(j.held?.mark == ".")
    }

    @Test func secondChunkNeedsJoinAndHoldsItsOwnMark() {
        var j = HeldMarkJoiner()
        _ = j.accept("Yes, that works for me.", pid: 1)
        let plan = j.accept("Send it to the team tomorrow morning.", pid: 1)
        guard case .needsJoin(let held, let next) = plan else { Issue.record("expected join"); return }
        #expect(held.mark == "." && held.body == "Yes, that works for me")
        #expect(next == "Send it to the team tomorrow morning")
        #expect(j.held?.mark == ".")
        #expect(j.resolve(previous: held, decision: .sentenceBreak, next: next) == ". Send it to the team tomorrow morning")
    }

    @Test func chunkWithoutMarkClearsHold() {
        var j = HeldMarkJoiner()
        _ = j.accept("first.", pid: 1)
        _ = j.accept("second without mark", pid: 1)
        #expect(j.held == nil)
        #expect(j.accept("third.", pid: 1) == .fresh(text: "third"))
    }

    @Test func stopTypesHeldMarkDiscardDropsIt() {
        var j = HeldMarkJoiner()
        _ = j.accept("Done?", pid: 1)
        #expect(j.stop() == "?")
        #expect(j.stop() == nil)
        _ = j.accept("Again.", pid: 1)
        j.discard()
        #expect(j.held == nil && j.stop() == nil)
    }

    @Test func appSwitchNeverJoins() {
        var j = HeldMarkJoiner()
        _ = j.accept("In Slack.", pid: 1)
        // A different app: no join; B is a fresh dictation (caller flushes the mark first).
        #expect(j.accept("In Mail.", pid: 2) == .fresh(text: "In Mail"))
    }

    @Test func flushReleasesMark() {
        var j = HeldMarkJoiner()
        _ = j.accept("Cursor moved.", pid: 1)
        #expect(j.flush() == ".")
        #expect(j.held == nil)
    }
}
