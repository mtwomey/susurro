import Foundation
import Testing
@testable import SusurroCore

@Suite struct PauseSegmenterTests {
    static let sr = 16_000
    /// Speech-like: 200 ms syllables with 60 ms gaps between them.
    static func tone(_ seconds: Double, amp: Float = 0.1, gap: Float = 0.0005) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { i in
            (i % 4_160) < 3_200 ? amp * sin(Float(i) * 0.2) : gap
        }
    }
    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.0005, count: Int(seconds * Double(sr)))
    }

    @Test func cutsAtPauseAfterSpeech() {
        var s = PauseSegmenter()
        let audio = Self.silence(0.2) + Self.tone(1.5) + Self.silence(1.0) + Self.tone(1.0)
        let cuts = s.append(audio)
        #expect(cuts.count == 1)
        let c = cuts[0]
        #expect(c.hasSpeech)
        // Inside the 1 s pause that starts at 1.7 s.
        #expect(c.sample > Int(1.7 * 16_000) && c.sample < Int(2.7 * 16_000))
        let last = s.finish(totalSamples: audio.count)
        #expect(last == PauseSegmenter.Cut(sample: audio.count, hasSpeech: true))
    }

    @Test func tracksLastSpeech() {
        var s = PauseSegmenter()
        #expect(s.lastSpeechSample == nil)
        _ = s.append(Self.silence(0.5) + Self.tone(1.0) + Self.silence(2.0))
        let last = s.lastSpeechSample ?? 0
        #expect(last > Int(1.3 * 16_000) && last <= Int(1.5 * 16_000) + 320)
    }

    @Test func shortPauseDoesNotCut() {
        var s = PauseSegmenter()
        let cuts = s.append(Self.tone(1.0) + Self.silence(0.3) + Self.tone(1.0))
        #expect(cuts.isEmpty)
    }

    @Test func tooLittleSpeechDoesNotCut() {
        var s = PauseSegmenter()
        let cuts = s.append(Self.tone(0.2) + Self.silence(2.0))
        #expect(cuts.isEmpty)
    }

    @Test func incrementalFeedMatchesBulk() {
        let audio = Self.tone(1.0) + Self.silence(1.0) + Self.tone(2.0) + Self.silence(1.0) + Self.tone(0.5)
        var bulk = PauseSegmenter()
        let a = bulk.append(audio)
        var inc = PauseSegmenter()
        var b: [PauseSegmenter.Cut] = []
        var i = 0
        while i < audio.count {
            let n = min(1_123, audio.count - i) // odd chunk sizes, like audio callbacks
            b += inc.append(Array(audio[i..<(i + n)]))
            i += n
        }
        #expect(a == b)
        #expect(a.count == 2, "\(a)")
    }

    @Test func cutsAreContiguousAndCoverEverything() {
        var s = PauseSegmenter()
        let audio = Self.tone(1.0) + Self.silence(1.0) + Self.tone(1.0) + Self.silence(1.0) + Self.tone(1.0)
        var bounds = [0]
        bounds += s.append(audio).map(\.sample)
        if let last = s.finish(totalSamples: audio.count) { bounds.append(last.sample) }
        #expect(bounds.last == audio.count)
        #expect(zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func forcedCutWhenNoPause() {
        var cfg = PauseSegmenter.Config()
        cfg.maxSegment = 5
        var s = PauseSegmenter(config: cfg)
        let cuts = s.append(Self.tone(12))
        #expect(cuts.count >= 2)
        #expect(cuts.allSatisfy { $0.sample <= 5 * 16_000 * cuts.count })
        #expect(cuts[0].sample <= 5 * 16_000 && cuts[0].sample >= Int(2.5 * 16_000))
    }

    @Test func silenceOnlyIsFlaggedNoSpeech() {
        var cfg = PauseSegmenter.Config()
        cfg.maxSegment = 2
        var s = PauseSegmenter(config: cfg)
        let cuts = s.append(Self.silence(5))
        #expect(!cuts.isEmpty)
        #expect(cuts.allSatisfy { !$0.hasSpeech })
    }

    @Test func finishWithNothingPendingReturnsNil() {
        var s = PauseSegmenter()
        let audio = Self.tone(1.0) + Self.silence(1.0)
        let cuts = s.append(audio)
        #expect(s.finish(totalSamples: s.currentSegmentStart) == nil)
        _ = cuts
    }
}

@Suite struct PauseSegmenterNoiseTests {
    @Test func learnsNoisyRoomAndStillFindsPauses() {
        // Room noise louder than minThreshold; speech well above it.
        func noise(_ s: Double) -> [Float] { (0..<Int(s * 16_000)).map { 0.012 * sin(Float($0) * 1.3) } }
        func voice(_ s: Double) -> [Float] { PauseSegmenterTests.tone(s, amp: 0.15, gap: 0.012) }
        var seg = PauseSegmenter()
        // Long noise lead-in lets the floor rise above the noise.
        let audio = noise(3) + voice(1.5) + noise(1.0) + voice(1.5) + noise(1.0) + voice(1.0)
        let cuts = seg.append(audio).filter(\.hasSpeech)
        #expect(cuts.count == 2, "\(cuts)")
    }
}
