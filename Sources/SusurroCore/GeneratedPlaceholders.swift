import Foundation

/// Placeholders drawn with CSS generated content (BEA-673).
///
/// Some Chromium/Electron editors draw their placeholder with
/// `[data-empty]::before { content: attr(data-placeholder) }` instead of an
/// HTML `placeholder`/`aria-placeholder`. Chromium then reports the
/// placeholder text as the empty field's `AXValue` (caret after it, plus a
/// `\n` from the editor's scaffolding `<br>` once text was typed and deleted)
/// and sets no `AXPlaceholderValue`, so nothing in the Accessibility tree
/// tells an empty field from one containing that text.
///
/// Last resort, per-app and clearly labelled: looked up by bundle ID so other
/// apps pay nothing. Prefer `kAXPlaceholderValueAttribute`, which the reader
/// always collects. Lists are the apps' shipped English strings.
public enum GeneratedPlaceholders {
    static let table: [String: [String]] = [
        // Hermes Agent desktop composer (apps/desktop i18n/en.ts
        // composer.newSessionPlaceholders / followUpPlaceholders).
        "com.nousresearch.hermes": [
            "What are we building?", "Give Hermes a task", "What's on your mind?",
            "Describe what you need", "What should we tackle?", "Ask anything",
            "Start with a goal",
            "Send a follow-up", "Add more context", "Refine the request",
            "What's next?", "Keep it going", "Push it further", "Adjust or continue",
        ],
    ]

    public static func placeholders(for bundleID: String?) -> [String] {
        guard let bundleID else { return [] }
        return table[bundleID] ?? []
    }
}
