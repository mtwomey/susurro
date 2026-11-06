import Foundation

/// Where hands-free audio comes from. `AudioRecorder` in the app; a fake
/// feeding fixture audio in tests.
public protocol AudioSource: AnyObject {
    /// Drains the samples captured since the last call.
    func takeAvailable() -> [Float]
    /// Stops capture and returns the remaining samples.
    func stop() -> [Float]
}

extension AudioRecorder: AudioSource {}

/// The hands-free audio plumbing (review F1/R4, was AppDelegate's hf*
/// buffer/segmenter state): drains a recorder, runs the pause segmenter, and
/// turns each cut into a speech chunk with its relative speech bounds. The app
/// keeps the timer, app-switch observer, gate and insertion; this part is pure
/// and testable with a fake source.
public struct HandsFreeSession {
    public typealias Chunk = DictationPipeline.ChunkAudio

    /// One pump's result: speech chunks ready to transcribe, in order, and
    /// whether new speech was heard (resets the idle timer).
    public struct Pump {
        public var chunks: [Chunk] = []
        public var heardSpeech = false
    }

    private var segmenter: PauseSegmenter
    private var buffer: [Float] = []    // samples of the unfinished segment
    private var bufferStart = 0         // absolute index of buffer[0]
    public private(set) var total = 0   // samples drained this session
    private var lastSpeech: Int?

    public init(tuning: Tuning = .default) {
        segmenter = tuning.makeSegmenter()
    }

    /// Timer tick: drain the source and segment what arrived.
    public mutating func pump(_ source: AudioSource) -> Pump {
        var out = Pump()
        out.chunks = feed(source.takeAvailable())
        if let last = segmenter.lastSpeechSample, last != lastSpeech {
            lastSpeech = last
            out.heardSpeech = true
        }
        return out
    }

    /// Session end with insert: stop the source, segment the rest and flush
    /// the final segment.
    public mutating func finish(_ source: AudioSource) -> [Chunk] {
        var chunks = feed(source.stop())
        if let last = segmenter.finish(totalSamples: total), let chunk = dispatch(last) {
            chunks.append(chunk)
        }
        buffer = []
        return chunks
    }

    /// Session end without insert (discard): stop the source, drop the audio.
    public mutating func discard(_ source: AudioSource) {
        _ = source.stop()
        buffer = []
    }

    private mutating func feed(_ samples: [Float]) -> [Chunk] {
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        total += samples.count
        return segmenter.append(samples).compactMap { dispatch($0) }
    }

    private mutating func dispatch(_ cut: PauseSegmenter.Cut) -> Chunk? {
        let sample = cut.sample
        let n = sample - bufferStart
        guard n > 0, n <= buffer.count else { return nil }
        // Drop a long pause's leading silence (BEA-657: 10-15 s thinking pauses).
        let start = HandsFreeJoin.trimmedStart(chunkStart: bufferStart, firstSpeech: cut.firstSpeech)
        let chunk = Array(buffer[(start - bufferStart)..<n])
        buffer.removeFirst(n)
        bufferStart = sample
        guard cut.hasSpeech else { return nil }
        return Chunk(samples: chunk,
                     firstSpeech: max(0, (cut.firstSpeech ?? start) - start),
                     lastSpeech: min(chunk.count, max(0, (cut.lastSpeech ?? sample) - start)))
    }
}
