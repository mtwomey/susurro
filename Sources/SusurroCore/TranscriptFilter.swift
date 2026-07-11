import Foundation

/// Removes whisper's non-speech hallucination tokens — on silence or noise it
/// emits things like "[BLANK_AUDIO]", "[MUSIC PLAYING]", "[inaudible]".
/// The Python version skipped any transcript starting with "["; this also
/// handles tokens embedded mid-transcript. Square brackets only — parentheses
/// are left alone since they can be legitimate dictated content.
public enum TranscriptFilter {
    public static func stripHallucinations(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "  +",
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
