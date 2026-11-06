import Foundation

/// The transcript side of a dictation (BEA-664, review R2 / F1, F4):
/// transcribe → TranscriptFilter → PostProcessor → optional LLM cleaner, plus
/// the joint-clip re-transcriptions that decide hands-free and cross-dictation
/// joins. The app (AppDelegate) and susurro-cli both run dictations through
/// this one type, so the CLI's eval output is the app's behaviour by
/// construction, not a hand-kept copy.
///
/// Field context, secure input and the actual typing stay in the app; this
/// type never touches Accessibility, the pasteboard or the main actor.
public struct DictationPipeline: Sendable {
    public let engine: any TranscriptionEngine
    public let postProcessor: PostProcessor
    /// Optional LLM cleanup; applied to a dictation's own text only, never to
    /// joint clips (which are read for punctuation at the join alone).
    public let cleaner: (any TextCleaning)?

    public init(engine: any TranscriptionEngine, postProcessor: PostProcessor, cleaner: (any TextCleaning)? = nil) {
        self.engine = engine
        self.postProcessor = postProcessor
        self.cleaner = cleaner
    }

    // MARK: - Text

    /// Engine-aware hallucination filter + PostProcessor rules, without
    /// sentence case (the pre-insert text stage decides case from what
    /// precedes the cursor). Empty after filtering → "".
    public func clean(_ transcript: String) -> String {
        let filtered = TranscriptFilter.stripHallucinations(transcript, engine: engine.kind)
        return filtered.isEmpty ? "" : postProcessor.process(filtered, applySentenceCase: false)
    }

    /// The standalone `--post` form: filter + PostProcessor with sentence
    /// case, as the A/B harness has always printed it.
    public func postProcessed(_ transcript: String) -> String {
        let filtered = TranscriptFilter.stripHallucinations(transcript, engine: engine.kind)
        return filtered.isEmpty ? "" : postProcessor.process(filtered)
    }

    /// `clean` + the optional LLM cleaner (a dictation's own words).
    public func cleanDictation(_ transcript: String) async -> String {
        var cleaned = clean(transcript)
        if let cleaner, !cleaned.isEmpty {
            cleaned = await cleaner.clean(cleaned) ?? cleaned
        }
        return cleaned
    }

    // MARK: - Joins

    /// Transcribe a joint clip (previous speech + real pause + new speech)
    /// and clean it for the join decision.
    public func jointText(_ clip: [Float]) throws -> String {
        clean(try engine.transcribe(samples: clip))
    }

    /// The previous hands-free chunk's audio, for the joint clip.
    public struct ChunkAudio: Sendable {
        public let samples: [Float]
        /// Index of the first / last speech sample within `samples`.
        public let firstSpeech: Int
        public let lastSpeech: Int
        public init(samples: [Float], firstSpeech: Int, lastSpeech: Int) {
            self.samples = samples
            self.firstSpeech = firstSpeech
            self.lastSpeech = lastSpeech
        }
    }

    /// Result of the hands-free join step for one chunk.
    public enum HandsFreeStep: Equatable, Sendable {
        /// Nothing was held: type the chunk as a normal dictation.
        case fresh(text: String)
        /// The previous chunk's held mark was decided from a joint clip.
        /// `joined` is what to type in place (mark or not + `next`).
        case joined(held: HeldMarkJoiner.Held, decision: HandsFreeJoin.Decision, next: String, joined: String)
        /// A mark was held but the previous chunk's audio is gone (cannot
        /// happen in a live session); nothing to decide.
        case unresolved
    }

    /// Decide a hands-free join for `plan` (from `HeldMarkJoiner.accept`).
    /// `jointSeconds` receives the joint transcription time, if any.
    public func handsFreeStep(_ plan: HeldMarkJoiner.Plan, previous: ChunkAudio?, current: ChunkAudio,
                              jointSeconds: inout Duration?) throws -> HandsFreeStep {
        switch plan {
        case .fresh(let text):
            return .fresh(text: text)
        case .needsJoin(let held, let next):
            guard let previous else { return .unresolved }
            let clip = HandsFreeJoin.jointClip(a: previous.samples, aLastSpeechEnd: previous.lastSpeech,
                                               b: current.samples, bFirstSpeechStart: current.firstSpeech)
            let clock = ContinuousClock(), start = clock.now
            let joint = try jointText(clip)
            jointSeconds = clock.now - start
            let decision = HandsFreeJoin.decide(previousBody: held.body, jointText: joint)
            return .joined(held: held, decision: decision, next: next,
                           joined: HandsFreeJoin.joined(mark: held.mark, decision: decision, next: next))
        }
    }

    /// Cross-dictation join (BEA-677): decide the previous dictation's full
    /// stop from a joint clip, when worth deciding. nil = no decision (the
    /// field guards then leave the previous text alone).
    public func crossDecision(previous: CrossDictationJoin.Previous?, previousAudio: ChunkAudio?,
                              samples: [Float], pid: pid_t?, startedAt: Date,
                              jointSeconds: inout Duration?) throws -> HandsFreeJoin.Decision? {
        guard let previous, let previousAudio,
              CrossDictationJoin.worthDeciding(previous: previous, pid: pid, startedAt: startedAt),
              let bounds = CrossDictationJoin.speechBounds(samples) else { return nil }
        let clip = HandsFreeJoin.jointClip(a: previousAudio.samples, aLastSpeechEnd: previousAudio.lastSpeech,
                                           b: samples, bFirstSpeechStart: bounds.first)
        let clock = ContinuousClock(), start = clock.now
        let joint = try jointText(clip)
        jointSeconds = clock.now - start
        return CrossDictationJoin.decide(previous: previous, jointText: joint)
    }
}
