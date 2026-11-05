import Foundation

/// Splits a growing hands-free recording into segments at natural pauses, so
/// each segment can be transcribed and inserted while the user keeps talking
/// (board choice on BEA-651: insert at each pause).
///
/// Pure and incremental: feed 16 kHz mono samples as they arrive; it returns
/// cut points as absolute sample indices. Every sample belongs to exactly one
/// segment (cuts are contiguous), so no audio is ever dropped.
public struct PauseSegmenter: Sendable {
    public struct Config: Sendable, Equatable {
        public var sampleRate: Int = 16_000
        public var frameMs: Int = 20
        /// Silence this long, after enough speech, ends a segment.
        public var minPause: Double = 0.7
        /// Speech needed in a segment before a pause may end it.
        public var minSpeech: Double = 0.6
        /// Hard cap; a longer segment is cut at its quietest frame.
        public var maxSegment: Double = 25
        /// Frame RMS below this is always silence.
        public var minThreshold: Float = 0.004
        /// Speech must be this many times louder than the tracked noise floor.
        public var floorRatio: Float = 3
        /// Floor = this percentile of the last `floorWindowFrames` frame levels.
        public var floorPercentile: Float = 0.1
        public var floorWindowFrames: Int = 250 // 5 s at 20 ms
        public init() {}
    }

    public struct Cut: Sendable, Equatable {
        /// Absolute sample index where the segment ends (exclusive).
        public let sample: Int
        /// False when the segment held no speech frames; callers may skip it.
        public let hasSpeech: Bool
    }

    public let config: Config
    private let frameLen: Int
    private var pending: [Float] = []
    private var consumed = 0              // samples framed so far
    private var segmentStart = 0          // absolute sample index
    private var frames: [(rms: Float, speech: Bool)] = [] // frames since segmentStart
    private var recent: [Float] = []         // recent frame RMS, for the floor

    public init(config: Config = Config()) {
        self.config = config
        self.frameLen = max(1, config.sampleRate * config.frameMs / 1000)
    }

    /// Absolute sample index at the end of the most recent speech frame.
    public private(set) var lastSpeechSample: Int?

    /// Absolute index of the start of the current (unfinished) segment.
    public var currentSegmentStart: Int { segmentStart }

    public mutating func append(_ samples: [Float]) -> [Cut] {
        pending.append(contentsOf: samples)
        var cuts: [Cut] = []
        var offset = 0
        while pending.count - offset >= frameLen {
            let frame = pending[offset..<(offset + frameLen)]
            offset += frameLen
            consumed += frameLen
            if let cut = process(frame: frame) { cuts.append(cut) }
        }
        pending.removeFirst(offset)
        return cuts
    }

    /// End of recording: the final segment runs to `totalSamples`.
    public mutating func finish(totalSamples: Int) -> Cut? {
        let hasSpeech = frames.contains { $0.speech }
        defer { reset(at: totalSamples) }
        guard totalSamples > segmentStart else { return nil }
        return Cut(sample: totalSamples, hasSpeech: hasSpeech)
    }

    private mutating func reset(at sample: Int) {
        pending = []
        consumed = sample
        segmentStart = sample
        frames = []
    }

    private mutating func process(frame: ArraySlice<Float>) -> Cut? {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()

        // Noise floor = a low percentile of recent frame levels. Speech always
        // has gaps between words, so this tracks the room, not the voice, and
        // adapts to a noisy room within a few seconds.
        recent.append(rms)
        if recent.count > config.floorWindowFrames { recent.removeFirst(recent.count - config.floorWindowFrames) }
        let sorted = recent.sorted()
        let floor = sorted[min(sorted.count - 1, Int(Float(sorted.count) * config.floorPercentile))]
        let speech = rms > max(config.minThreshold, floor * config.floorRatio)
        frames.append((rms, speech))
        if speech { lastSpeechSample = consumed }

        let fps = 1000.0 / Double(config.frameMs)
        let minPauseFrames = Int((config.minPause * fps).rounded())
        let minSpeechFrames = Int((config.minSpeech * fps).rounded())
        let maxFrames = Int((config.maxSegment * fps).rounded())

        // Natural pause: trailing silence run long enough, after enough speech.
        var silenceRun = 0
        for f in frames.reversed() { if f.speech { break }; silenceRun += 1 }
        let speechCount = frames.lazy.filter { $0.speech }.count
        if silenceRun >= minPauseFrames && speechCount >= minSpeechFrames {
            // Cut halfway into the pause: some trailing silence stays with the
            // segment (engines like a little), the rest leads the next one.
            let cutFrame = frames.count - silenceRun + silenceRun / 2
            return cut(atFrame: cutFrame)
        }

        // Too long: cut at the quietest frame in the second half.
        if frames.count >= maxFrames {
            let lo = frames.count / 2
            var best = lo
            for i in lo..<frames.count where frames[i].rms < frames[best].rms { best = i }
            return cut(atFrame: best + 1)
        }
        return nil
    }

    private mutating func cut(atFrame n: Int) -> Cut {
        let hasSpeech = frames[..<n].contains { $0.speech }
        let sample = segmentStart + n * frameLen
        frames.removeFirst(n)
        segmentStart = sample
        return Cut(sample: sample, hasSpeech: hasSpeech)
    }
}
