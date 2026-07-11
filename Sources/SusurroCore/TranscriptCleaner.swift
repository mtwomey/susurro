import Foundation
import FoundationModels

/// Availability-agnostic interface so callers on any macOS can hold a cleaner.
public protocol TextCleaning: Sendable {
    func prewarm()
    func clean(_ text: String) async -> String?
}

/// Optional AI cleanup pass over transcripts using Apple's on-device Foundation
/// Models (requires Apple Intelligence). Strictly corrective by prompt design:
/// probe testing showed permissive prompts *rewrite* ("and stuff" → "and other
/// related technologies"), which a dictation tool must never do.
@available(macOS 26.0, *)
public final class TranscriptCleaner: TextCleaning, @unchecked Sendable {
    public enum Availability: Sendable {
        case available
        case appleIntelligenceNotEnabled
        case modelNotReady
        case notSupported
    }

    public static func availability() -> Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .notSupported
        }
    }

    private static let instructions = """
    You correct dictated text. Apply ONLY these fixes:
    - capitalization and punctuation
    - obvious grammatical errors
    - remove filler words: um, uh, you know, like (only when used as filler)
    Rules you must never break:
    - do NOT rephrase or substitute words
    - do NOT change slang, tone, or meaning ("and stuff" stays "and stuff")
    - do NOT alter technical terms, names, or numbers
    - output ONLY the corrected text — no commentary, no quotation marks around it
    """

    public init() {}

    /// Prepare the model so the first real cleanup isn't cold.
    public func prewarm() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    /// Guided-generation schema: constrains decoding so the model structurally
    /// cannot emit preamble like "Here is the corrected text:".
    @Generable
    struct CleanedTranscript {
        @Guide(description: "The corrected text only — no commentary or preamble")
        var text: String
    }

    /// Below this, a grammar pass isn't worth the latency — quick dictations
    /// ("yes, sounds good") go straight through.
    private static let minimumWords = 6

    /// Returns cleaned text, or nil if unavailable/failed/too short — caller
    /// falls back to input. A fresh session per call keeps it stateless
    /// (sessions accumulate context).
    public func clean(_ text: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        guard text.split(separator: " ").count >= Self.minimumWords else { return nil }
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let t0 = Date()
            let response = try await session.respond(
                to: text,
                generating: CleanedTranscript.self,
                options: GenerationOptions(sampling: .greedy)
            )
            let cleaned = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[susurro] cleanup: %.2fs", -t0.timeIntervalSinceNow)
            // Sanity guard: a corrective pass shouldn't change length drastically.
            // If it did, the model went off-script — prefer the raw transcript.
            guard !cleaned.isEmpty,
                  cleaned.count > text.count / 2,
                  cleaned.count < text.count * 2
            else {
                NSLog("[susurro] cleanup output failed sanity check — using raw text")
                return nil
            }
            return cleaned
        } catch {
            NSLog("[susurro] cleanup failed: %@", String(describing: error))
            return nil
        }
    }
}
