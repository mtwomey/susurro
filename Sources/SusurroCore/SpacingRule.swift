import Foundation

/// Pure decision logic for Smart Spacing: given the text Susurro itself
/// last typed immediately before the cursor (as tracked by
/// `DictationMemory`), decide whether the next dictated transcript should
/// get a leading space prepended. Deliberately has no Accessibility/AppKit
/// dependency so it can be unit-tested without a live focused text field —
/// see docs/SMART_SPACING_PLAN.md.
public enum SpacingRule {
    /// A resumed dictation always gets a leading space — in practice you're
    /// never picking up mid-word, so any continuation needs a word boundary
    /// — *unless* the last typed text already ends in whitespace (a space or
    /// a newline), in which case adding another would double it up. nil (no
    /// prior dictation into this same still-focused app) always yields
    /// false, matching Smart Spacing's "any uncertainty means do nothing"
    /// fallback.
    public static func needsLeadingSpace(beforeCursor tail: String?) -> Bool {
        guard let tail, let last = tail.last else { return false }
        return !last.isWhitespace
    }
}
