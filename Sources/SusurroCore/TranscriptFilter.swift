import Foundation

/// Removes whisper's non-speech hallucination tokens — on silence or noise it
/// emits things like "[BLANK_AUDIO]", "[MUSIC PLAYING]", "[inaudible]".
/// The Python version skipped any transcript starting with "["; this also
/// handles tokens embedded mid-transcript. Square brackets only — parentheses
/// are left alone since they can be legitimate dictated content.
///
/// Capability-driven: the bracket-token strip applies only to engines with
/// `emitsBracketTokens` (whisper). Parakeet (TDT, CTC-style decoding) has no
/// such tokens — silence comes back as "" — so for it only whitespace is
/// normalised and any brackets are kept as text.
public enum TranscriptFilter {
    public static func stripHallucinations(_ text: String, engine: EngineKind = .whisper) -> String {
        stripHallucinations(text, capabilities: engine.capabilities)
    }

    public static func stripHallucinations(_ text: String, capabilities: EngineCapabilities) -> String {
        var result = text
        if capabilities.emitsBracketTokens {
            result = result.replacingOccurrences(
                of: "\\[[^\\]]*\\]",
                with: "",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(
            of: "  +",
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
