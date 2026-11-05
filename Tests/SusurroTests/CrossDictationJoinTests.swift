import Foundation
import Testing
@testable import SusurroCore

struct CrossDictationJoinTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func prev(_ typed: String = "Yesterday I went to the store.", pid: pid_t = 42,
              field: String? = "f1", position: ValuePosition? = nil) -> CrossDictationJoin.Previous {
        .init(typed: typed, pid: pid, fieldID: field, endedAt: t0, position: position)
    }

    func cur(before: String? = "Notes: Yesterday I went to the store.", pid: pid_t = 42, field: String? = "f1",
             after: String? = nil, gap: TimeInterval = 3, position: ValuePosition? = nil,
             typed: Int? = 0) -> CrossDictationJoin.Current {
        .init(pid: pid, fieldID: field, startedAt: t0.addingTimeInterval(gap), before: before,
              after: after, position: position, userKeystrokesSince: typed)
    }

    @Test func eligibleWhenUntouchedAndSoon() {
        let v = CrossDictationJoin.check(previous: prev(), current: cur())
        #expect(v == .eligible(mark: ".", previousBody: "Yesterday I went to the store"))
    }

    @Test func leadingSpaceInTypedTextIsIgnored() {
        let v = CrossDictationJoin.check(previous: prev(" And bought bananas."),
                                         current: cur(before: "the store. And bought bananas."))
        #expect(v == .eligible(mark: ".", previousBody: "And bought bananas"))
    }

    @Test func guards() {
        typealias R = CrossDictationJoin.Reason
        func reason(_ p: CrossDictationJoin.Previous?, _ c: CrossDictationJoin.Current) -> R? {
            if case .ineligible(let r) = CrossDictationJoin.check(previous: p, current: c) { return r }
            return nil
        }
        #expect(reason(nil, cur()) == .noPrevious)
        #expect(reason(prev(), cur(pid: 7)) == .differentApp)
        #expect(reason(prev(), cur(field: "f2")) == .differentField)
        #expect(reason(prev(), cur(gap: 30)) == .gapTooLong)
        #expect(reason(prev(), cur(gap: -1)) == .gapTooLong)
        #expect(reason(prev("Are you coming?"), cur(before: "Are you coming?")) == .noPeriod)
        #expect(reason(prev("Great!"), cur(before: "Great!")) == .noPeriod)
        #expect(reason(prev("Wait..."), cur(before: "Wait...")) == .noPeriod)
        #expect(reason(prev("no mark"), cur(before: "no mark")) == .noPeriod)
        // User edited the text (changed a word, or removed the period).
        #expect(reason(prev(), cur(before: "Yesterday I went to the shop.")) == .edited)
        #expect(reason(prev(), cur(before: "Yesterday I went to the store")) == .edited)
        // User typed after it (even a space).
        #expect(reason(prev(), cur(before: "Yesterday I went to the store. ")) == .edited)
        #expect(reason(prev(), cur(typed: 2)) == .typedSince)
        // Cursor moved back into the text.
        #expect(reason(prev(), cur(after: " more text")) == .textAfterCursor)
        #expect(reason(prev(position: .init(caretOffset: 30, valueLength: 30)),
                       cur(position: .init(caretOffset: 30, valueLength: 31))) == .positionMoved)
        // Cannot read the field: never delete blind.
        #expect(reason(prev(), cur(before: nil)) == .unreadable)
    }

    @Test func unknownFieldIDsDoNotBlock() {
        let v = CrossDictationJoin.check(previous: prev(field: nil), current: cur(field: "f1"))
        if case .eligible = v {} else { Issue.record("expected eligible, got \(v)") }
    }

    @Test func continuationDeletesOneMarkAndLowercases() {
        let e = CrossDictationJoin.edit(decision: .continuation, next: " And bought bananas.")
        #expect(e.deleteBackward == 1)
        #expect(e.text == " and bought bananas.")
        let i = CrossDictationJoin.edit(decision: .continuation, next: " I think so.")
        #expect(i.text == " I think so.")
    }

    @Test func breakKeepsEverything() {
        #expect(CrossDictationJoin.edit(decision: .sentenceBreak, next: " Today I plan.") == (0, " Today I plan."))
        #expect(CrossDictationJoin.edit(decision: .unmatched, next: " Today I plan.") == (0, " Today I plan."))
    }

    @Test func boardRepro() {
        // "Yesterday I went to the store. And bought bananas." split mid-sentence.
        let d = HandsFreeJoin.decide(previousBody: "Yesterday I went to the store",
                                     jointText: "went to the store and bought bananas.")
        #expect(d == .continuation)
        let d2 = HandsFreeJoin.decide(previousBody: "And bought bananas",
                                      jointText: "and bought bananas. Today I plan.")
        #expect(d2 == .sentenceBreak)
    }

    @Test func worthDecidingPrecheck() {
        #expect(CrossDictationJoin.worthDeciding(previous: prev(), pid: 42, startedAt: t0.addingTimeInterval(5)))
        #expect(!CrossDictationJoin.worthDeciding(previous: prev(), pid: 7, startedAt: t0.addingTimeInterval(5)))
        #expect(!CrossDictationJoin.worthDeciding(previous: prev(), pid: 42, startedAt: t0.addingTimeInterval(60)))
        #expect(!CrossDictationJoin.worthDeciding(previous: prev("Really?"), pid: 42, startedAt: t0.addingTimeInterval(5)))
        #expect(!CrossDictationJoin.worthDeciding(previous: nil, pid: 42, startedAt: t0))
    }

    @Test func speechBoundsOfAWholeClip() {
        // 1 s silence, 1 s tone, 1 s silence at 16 kHz.
        var samples = [Float](repeating: 0.0005, count: 48_000)
        for i in 16_000..<32_000 { samples[i] = 0.2 * sin(Float(i) * 0.1) }
        let b = CrossDictationJoin.speechBounds(samples)
        #expect(b != nil)
        if let b {
            #expect(abs(b.first - 16_000) <= 640)
            #expect(abs(b.last - 32_000) <= 640)
        }
        #expect(CrossDictationJoin.speechBounds([Float](repeating: 0, count: 16_000)) == nil)
    }

    @Test func logLineHasNoText() {
        let v = CrossDictationJoin.Verdict.eligible(mark: ".", previousBody: "secret words")
        let line = CrossDictationJoin.logLine(verdict: v, gap: 3.25, decision: .continuation)
        #expect(line == "xjoin=continue gap=3.2" || line == "xjoin=continue gap=3.3")
        #expect(!line.contains("secret"))
        #expect(CrossDictationJoin.logLine(verdict: .ineligible(.edited), gap: nil, decision: nil) == "xjoin=skip reason=edited gap=-")
    }
}
