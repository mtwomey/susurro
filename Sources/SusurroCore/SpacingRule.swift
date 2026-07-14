import Foundation

/// Pure decision logic for Smart Spacing: given a short raw slice of text
/// immediately before the cursor (as read by `FocusedFieldInspector`),
/// decide whether the next dictated transcript should get a leading space
/// prepended. Deliberately has no Accessibility/AppKit dependency so it can
/// be unit-tested without a live focused text field — see SMART_SPACING_PLAN.md.
public enum SpacingRule {
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    private static let closingWrappers: Set<Character> = ["\"", "'", ")", "\u{201D}", "\u{2019}", "\u{00BB}", "\u{203A}"]

    /// `tail` is the raw text immediately before the cursor, with trailing
    /// whitespace/newlines *not yet* stripped — this function strips them.
    /// nil (unreadable field) always yields false, matching Smart Spacing's
    /// "any uncertainty means do nothing" fallback.
    public static func needsLeadingSpace(beforeCursor tail: String?) -> Bool {
        guard let tail else { return false }

        // Character.isWhitespace covers newlines too, so this one drop(while:)
        // handles both "ends in trailing spaces" and "ends in a blank line."
        let trimmed = String(tail.reversed().drop(while: \.isWhitespace).reversed())
        guard let last = trimmed.last else { return false }

        if sentenceEnders.contains(last) { return true }

        if closingWrappers.contains(last) {
            let prior = trimmed.dropLast().last
            return prior.map(sentenceEnders.contains) ?? false
        }

        return false
    }
}
