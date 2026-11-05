import Foundation

// Pre-insert text-handling stage (BEA-648, design in docs/TEXT_HANDLING_FINDINGS.md §3-4).
//
// Runs on the main actor right before `TextInjector.type`, after PostProcessor
// and AI Cleanup, so the context-dependent decisions (leading space, case of the
// first word) are made last and nothing upstream can undo them. Every transform
// is a pure function of (text, InsertContext) so it can be unit-tested without a
// live text field. Field text must never be logged.

/// Where `InsertContext.before` came from.
public enum ContextSource: String, Sendable, Equatable {
    /// Read from the focused field through Accessibility.
    case accessibility
    /// Susurro's own memory of what it last typed into this app.
    case selfTracked
    /// A readable value with no readable cursor (terminals, Emacs), with the
    /// cursor located by anchoring on what Susurro last typed — see
    /// `AnchoredValueProvider`.
    case anchoredValue
    /// The app itself reported the text before the cursor (app bridge).
    case appBridge
    /// Nothing known: treated as an empty field (board decision 2).
    case none
}

public struct InsertContext: Sendable, Equatable {
    /// Text before the cursor; nil = unknown.
    public var before: String?
    /// Text after the cursor (Accessibility only); nil = unknown.
    public var after: String?
    public var source: ContextSource
    public var pid: pid_t?
    public var bundleID: String?
    public var engine: EngineKind?
    public var secureInput: Bool

    public init(before: String?, after: String? = nil, source: ContextSource,
                pid: pid_t? = nil, bundleID: String? = nil,
                engine: EngineKind? = nil, secureInput: Bool = false) {
        self.before = before
        self.after = after
        self.source = source
        self.pid = pid
        self.bundleID = bundleID
        self.engine = engine
        self.secureInput = secureInput
    }

    /// No context at all — the empty-field policy applies.
    public static let unknown = InsertContext(before: nil, source: .none)

    /// True when the dictation starts a sentence: unknown/empty context, the
    /// cursor at the start of a line, or the preceding text ends in `.?!`
    /// (optionally followed by closing quotes/brackets, then any spaces).
    public var startsSentence: Bool {
        guard let before else { return true }
        var trimmed = Substring(before)
        while let last = trimmed.last, last == " " || last == "\t" || last == "\u{00A0}" {
            trimmed = trimmed.dropLast()
        }
        guard let lastChar = trimmed.last else { return true }
        if lastChar.isNewline { return true }
        while let last = trimmed.last, InsertContext.closers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let end = trimmed.last else { return true }
        return InsertContext.sentenceEnders.contains(end)
    }

    static let sentenceEnders: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
}

public protocol TextTransform: Sendable {
    var name: String { get }
    func apply(_ text: String, _ context: InsertContext) -> String
}

/// Replaces SpacingRule: prepend one space only when the cursor follows a
/// non-whitespace character that is not an opening bracket or quote. Never at
/// the start of a field (or unknown context), never after a space the user
/// typed. Leading spaces/tabs on the transcript itself are dropped first so
/// AI Cleanup output can't double them up.
public struct LeadingSpace: TextTransform {
    public let name = "LeadingSpace"
    public init() {}

    static let openers: Set<Character> = ["(", "[", "{", "“", "‘", "«", "¿", "¡"]
    static let attachedPunctuation: Set<Character> = [",", ".", "?", "!", ";", ":", ")", "]", "}", "…", "%"]

    public func apply(_ text: String, _ context: InsertContext) -> String {
        var body = Substring(text)
        while let first = body.first, first == " " || first == "\t" { body = body.dropFirst() }
        guard let first = body.first else { return String(body) }
        guard let before = context.before, let last = before.last else { return String(body) }
        if last.isWhitespace { return String(body) }
        if first.isNewline || LeadingSpace.attachedPunctuation.contains(first) { return String(body) }
        if LeadingSpace.openers.contains(last) { return String(body) }
        if last == "\"" || last == "'" {
            // Straight quotes are ambiguous: an opener when nothing or
            // whitespace precedes it, a closer otherwise.
            let prev = before.dropLast().last
            if prev == nil || prev!.isWhitespace || LeadingSpace.openers.contains(prev!) {
                return String(body)
            }
        }
        return " " + body
    }
}

/// Lower-cases the first word when the dictation continues a sentence. The
/// engines emit sentence-cased output, so switching capitalisation off is not
/// enough. "I" and its contractions, and words with more than one capital
/// (acronyms, "iOS", "McDonald"), are kept.
public struct ContinuationCase: TextTransform {
    public let name = "ContinuationCase"
    public init() {}

    public func apply(_ text: String, _ context: InsertContext) -> String {
        guard !context.startsSentence else { return text }
        guard let range = firstWordRange(text) else { return text }
        let word = text[range]
        guard let first = word.first, first.isUppercase else { return text }
        let isPronounI = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
        let uppercaseCount = word.filter(\.isUppercase).count
        guard !isPronounI, uppercaseCount == 1 else { return text }
        return text.replacingCharacters(in: range, with: first.lowercased() + word.dropFirst())
    }

    private func firstWordRange(_ text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(where: { $0.isLetter }) else { return nil }
        // Only the very first token: leading punctuation like a quote is fine,
        // but a line break before the first word starts a new line anyway.
        if text[text.startIndex..<start].contains(where: { $0.isNewline }) { return nil }
        var end = start
        while end < text.endIndex, text[end].isLetter || text[end] == "'" || text[end] == "’" {
            end = text.index(after: end)
        }
        return start..<end
    }
}

/// PostProcessor step 7 moved here so it can see context: upper-case the
/// first letter when the dictation starts a sentence. Enabled by rules.json
/// `options.autoCapitalize` (kept for compatibility).
public struct SentenceCase: TextTransform {
    public let name = "SentenceCase"
    public init() {}

    public func apply(_ text: String, _ context: InsertContext) -> String {
        guard context.startsSentence else { return text }
        guard let index = text.firstIndex(where: { !$0.isWhitespace }) else { return text }
        let first = text[index]
        guard first.isLowercase else { return text }
        return text.replacingCharacters(in: index...index, with: first.uppercased())
    }
}

/// The ordered stage. Case transforms run before LeadingSpace so they look at
/// the transcript's own first word, not a prepended space.
public struct TextHandlingStage: Sendable {
    public var transforms: [any TextTransform]

    public init(transforms: [any TextTransform]) {
        self.transforms = transforms
    }

    /// The default ordering. `smartSpacing` is the existing menu toggle;
    /// `autoCapitalize` is rules.json `options.autoCapitalize`.
    public static func standard(smartSpacing: Bool, autoCapitalize: Bool) -> TextHandlingStage {
        var steps: [any TextTransform] = []
        if smartSpacing { steps.append(ContinuationCase()) }
        if autoCapitalize { steps.append(SentenceCase()) }
        if smartSpacing { steps.append(LeadingSpace()) }
        return TextHandlingStage(transforms: steps)
    }

    public func apply(_ text: String, _ context: InsertContext) -> String {
        transforms.reduce(text) { $1.apply($0, context) }
    }
}
