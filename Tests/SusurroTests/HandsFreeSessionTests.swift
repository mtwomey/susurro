import Foundation
import Testing
@testable import SusurroCore

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// Plays fixture audio like the live recorder: each `takeAvailable()` returns
/// the next `step` samples; `stop()` returns whatever is left.
private final class FakeRecorder: AudioSource {
    private let samples: [Float]
    private let step: Int
    private(set) var position = 0
    private(set) var stopped = false
    init(_ samples: [Float], step: Int) { self.samples = samples; self.step = step }
    var exhausted: Bool { position >= samples.count }
    func takeAvailable() -> [Float] {
        let end = min(samples.count, position + step)
        defer { position = end }
        return Array(samples[position..<end])
    }
    func stop() -> [Float] {
        stopped = true
        defer { position = samples.count }
        return Array(samples[position...])
    }
}

@Suite(.serialized) struct HandsFreeSessionTests {
    /// Loaded and segmented once: the suite is CPU-bound and runs beside
    /// wall-clock tests (DictationTimingTests), so keep its work small.
    private static let fixture: [Float]? = try? loadFixture()
    private static let expected: [HandsFreeSession.Chunk] = fixture.map(reference) ?? []

    private func fixtureSession() throws -> [Float] {
        try #require(Self.fixture)
    }

    /// Three fixture clips separated by 2 s of silence (> 1 s minPause), so a
    /// session must cut at least once per clip.
    private static func loadFixture() throws -> [Float] {
        let silence = [Float](repeating: 0, count: 32_000)
        var out: [Float] = []
        for name in ["clip1", "clip2", "clip3"] {
            let url = repoRoot.appendingPathComponent("Fixtures/\(name).wav")
            out += try AudioFileLoader.loadSamples(url: url) + silence
        }
        return out
    }

    /// Reference: segment the whole clip at once (the CLI replay's slicing).
    private static func reference(_ samples: [Float]) -> [HandsFreeSession.Chunk] {
        var seg = PauseSegmenter()
        var cuts: [PauseSegmenter.Cut] = []
        var fed = 0
        while fed < samples.count {
            let end = min(samples.count, fed + 1600)
            cuts += seg.append(Array(samples[fed..<end])); fed = end
        }
        if let last = seg.finish(totalSamples: samples.count) { cuts.append(last) }
        var start = 0
        var out: [HandsFreeSession.Chunk] = []
        for cut in cuts {
            let s0 = HandsFreeJoin.trimmedStart(chunkStart: start, firstSpeech: cut.firstSpeech)
            let chunk = Array(samples[s0..<cut.sample]); start = cut.sample
            guard cut.hasSpeech else { continue }
            out.append(.init(samples: chunk,
                             firstSpeech: max(0, (cut.firstSpeech ?? s0) - s0),
                             lastSpeech: min(chunk.count, max(0, (cut.lastSpeech ?? cut.sample) - s0))))
        }
        return out
    }

    private func run(_ samples: [Float], step: Int, stopAt: Int? = nil)
        -> (chunks: [HandsFreeSession.Chunk], heard: Int, total: Int) {
        let rec = FakeRecorder(samples, step: step)
        var session = HandsFreeSession()
        var chunks: [HandsFreeSession.Chunk] = [], heard = 0, pumps = 0
        while !rec.exhausted, pumps != stopAt {
            let p = session.pump(rec)
            chunks += p.chunks
            if p.heardSpeech { heard += 1 }
            pumps += 1
        }
        chunks += session.finish(rec)
        #expect(rec.stopped)
        return (chunks, heard, session.total)
    }

    private func same(_ a: [HandsFreeSession.Chunk], _ b: [HandsFreeSession.Chunk]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.samples == $1.samples && $0.firstSpeech == $1.firstSpeech && $0.lastSpeech == $1.lastSpeech
        }
    }

    /// Live pumping (100 ms timer ticks of 1,600 samples) yields exactly the
    /// chunks of whole-clip segmentation: same audio, same speech bounds, in order.
    @Test func fixtureAudioChunksMatchWholeClipSegmentation() throws {
        let audio = try fixtureSession()
        let expected = Self.expected
        #expect(expected.count >= 3)
        let got = run(audio, step: 1_600)
        #expect(same(got.chunks, expected))
        #expect(got.total == audio.count)
        #expect(got.heard > 0)
        for c in got.chunks {
            #expect(c.firstSpeech >= 0 && c.firstSpeech <= c.lastSpeech && c.lastSpeech <= c.samples.count)
        }
    }

    /// Irregular delivery sizes (audio-thread jitter) don't change the chunks.
    @Test(arguments: [480, 16_000])
    func deliverySizeDoesNotChangeChunks(_ step: Int) throws {
        let audio = try fixtureSession()
        #expect(same(run(audio, step: step).chunks, Self.expected))
    }

    /// Stopping mid-session: samples still in the recorder come back from
    /// stop() and are segmented and flushed — no audio lost.
    @Test func finishFlushesRecorderRemainder() throws {
        let audio = try fixtureSession()
        let got = run(audio, step: 1_600, stopAt: 10)
        #expect(got.total == audio.count)
        #expect(same(got.chunks, Self.expected))
    }

    /// Discard stops the recorder and yields nothing further.
    @Test func discardDropsAudio() throws {
        let audio = try fixtureSession()
        let rec = FakeRecorder(audio, step: 1_600)
        var session = HandsFreeSession()
        _ = session.pump(rec)
        session.discard(rec)
        #expect(rec.stopped)
        #expect(session.pump(rec).chunks.isEmpty)
    }

    /// Pure silence never produces a chunk or a heard-speech event.
    @Test func silenceProducesNothing() {
        let got = run([Float](repeating: 0, count: 160_000), step: 1_600)
        #expect(got.chunks.isEmpty)
        #expect(got.heard == 0)
    }
}
