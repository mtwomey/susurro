import Foundation

/// Rules schema for rules.json — see Resources/rules.json for the documented default.
public struct PostProcessingRules: Codable, Sendable {
    public struct Options: Codable, Sendable {
        public var pairQuotes: Bool
        public var autoCapitalize: Bool
        public var normalizeWhitespace: Bool
    }

    public struct PunctuationRule: Codable, Sendable {
        public var say: String
        public var insert: String
        public var enabled: Bool?
        /// When true, a space immediately before the inserted symbol is
        /// stripped during whitespace cleanup — e.g. colon/semicolon, which
        /// should hug the preceding word ("word:" not "word :"). The four
        /// classic sentence-enders (,.?!) already get this for free below,
        /// so they don't need the flag; it exists for everything else.
        public var noSpaceBefore: Bool?
        var isEnabled: Bool { enabled ?? true }
        var isNoSpaceBefore: Bool { noSpaceBefore ?? false }
    }

    public struct SubstitutionRule: Codable, Sendable {
        public var match: String
        public var replace: String
        public var enabled: Bool?
        var isEnabled: Bool { enabled ?? true }
    }

    public struct RegexRule: Codable, Sendable {
        public var pattern: String
        public var template: String
        public var enabled: Bool?
        var isEnabled: Bool { enabled ?? true }
    }

    public var options: Options
    public var punctuation: [PunctuationRule]
    public var substitutions: [SubstitutionRule]
    public var regexRules: [RegexRule]
}

/// Verbal punctuation & transcript fix-up pipeline. Swift port of the Python
/// `apply_verbal_punctuation`, pinned by golden tests, with two deliberate fixes:
/// "new line" actually inserts a newline (Python collapsed it away), and
/// "backslash" inserts one backslash (Python inserted two).
///
/// Rules load fresh from the user's rules.json on every call — live reload for free.
public final class PostProcessor: @unchecked Sendable {
    public let userRulesURL: URL

    public static var defaultUserRulesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Susurro/rules.json")
    }

    public init(userRulesURL: URL = PostProcessor.defaultUserRulesURL) {
        self.userRulesURL = userRulesURL
        ensureUserRulesFile()
    }

    /// Write the embedded default rules to the user location on first run.
    private func ensureUserRulesFile() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: userRulesURL.path) else { return }
        try? fm.createDirectory(
            at: userRulesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? DefaultRules.data.write(to: userRulesURL)
    }

    public func loadRules() -> PostProcessingRules? {
        let decoder = JSONDecoder()
        // User file first; fall back to embedded default (e.g. user file is invalid JSON)
        if let data = try? Data(contentsOf: userRulesURL),
           let rules = try? decoder.decode(PostProcessingRules.self, from: data) {
            return rules
        }
        if let rules = DefaultRules.decoded() {
            NSLog("[susurro] rules.json unreadable at %@ — using embedded defaults",
                  userRulesURL.path)
            return rules
        }
        return nil
    }

    /// `applySentenceCase: false` leaves step 7 to the pre-insert
    /// `TextHandlingStage` (BEA-648), which can see the field context.
    /// rules.json `options.autoCapitalize`, for configuring `SentenceCase`.
    public var autoCapitalizeEnabled: Bool {
        loadRules()?.options.autoCapitalize ?? true
    }

    public func process(_ text: String, applySentenceCase: Bool = true) -> String {
        guard let rules = loadRules() else { return text }
        var result = text

        let enabledPunctuation = rules.punctuation.filter(\.isEnabled)

        // 0. Engines that punctuate and case their own output (Parakeet) end a
        //    "sentence" at a spoken mid-sentence trigger: "Note colon. Buy milk."
        //    The model's period is stripped in step 1, so its sentence-start
        //    capital would otherwise survive: "Note: Buy milk". Lowercase it.
        let midSentenceSays = enabledPunctuation
            .filter { [",", ";", ":"].contains($0.insert) }
            .map(\.say)
        result = lowercaseAfterMidSentenceTrigger(result, says: midSentenceSays)

        // 1. Strip stray punctuation that the engine places around trigger
        //    words: "quote, wow, end quote." -> "quote wow end quote". After
        //    the trigger, any of , . ? ! ; : goes — the trigger supplies the
        //    symbol, so a punctuating engine's own one would double it
        //    ("ready question mark?" -> "ready??"). Before it, only , and .
        //    (the original whisper rule), so a real "?" ahead of "new line"
        //    survives.
        var keywords: [String] = []
        if rules.options.pairQuotes { keywords += ["quote", "end quote"] }
        keywords += enabledPunctuation.map(\.say)
        for keyword in keywords {
            let escaped = NSRegularExpression.escapedPattern(for: keyword)
            // Whisper sometimes renders the spoken quote itself as real quote
            // marks around the triggers ("\"quote hi end quote\""); pairing
            // would then double them. Only the quote triggers eat quote marks,
            // so a genuine closing quote before e.g. "comma" survives.
            let q = (keyword == "quote" || keyword == "end quote") ? "\"\u{201C}\u{201D}" : ""
            result = replace(in: result,
                             pattern: "[,.\(q)]?\\s*\\b(\(escaped))\\b\\s*[,.?!;:\(q)]?",
                             template: " $1 ")
        }

        // 2. Pair quotes: "quote ... end quote" -> "..."
        if rules.options.pairQuotes {
            result = replace(in: result,
                             pattern: "\\bquote\\b\\s*(.*?)\\s*\\bend quote\\b",
                             template: "\"$1\"")
        }

        // 3. Spoken punctuation -> symbols
        for rule in enabledPunctuation {
            let escaped = NSRegularExpression.escapedPattern(for: rule.say)
            result = replace(in: result,
                             pattern: "\\b\(escaped)\\b",
                             template: NSRegularExpression.escapedTemplate(for: rule.insert))
        }

        // 4. Plain-text substitutions (jargon fix-ups)
        for rule in rules.substitutions.filter(\.isEnabled) {
            let escaped = NSRegularExpression.escapedPattern(for: rule.match)
            result = replace(in: result,
                             pattern: "\\b\(escaped)\\b",
                             template: NSRegularExpression.escapedTemplate(for: rule.replace))
        }

        // 5. Raw regex rules (power users)
        for rule in rules.regexRules.filter(\.isEnabled) {
            result = replace(in: result, pattern: rule.pattern, template: rule.template)
        }

        // 6. Whitespace cleanup. Divergence from Python: newlines survive.
        if rules.options.normalizeWhitespace {
            result = replace(in: result, pattern: "[ \\t]+", template: " ")
            result = replace(in: result, pattern: " *\\n *", template: "\n")
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // "word ." -> "word.", "word , word" -> "word, word" for the
            // classic sentence-enders, plus any punctuation rule that opted
            // in via "noSpaceBefore": true (e.g. colon, semicolon, or any
            // custom symbol a user adds to their own rules.json).
            let extraAttached = enabledPunctuation
                .filter(\.isNoSpaceBefore)
                .map(\.insert)
                .filter { !$0.isEmpty }
            let alternatives = (["[,.?!]"] + extraAttached.map {
                NSRegularExpression.escapedPattern(for: $0)
            }).joined(separator: "|")
            result = replace(in: result, pattern: "[ \\t]+(\(alternatives))", template: "$1")
        }

        // 7. Capitalize a sentence-start-like string
        if applySentenceCase, rules.options.autoCapitalize, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }

    /// "comma. Then" -> "comma. then": a capitalised word directly after a
    /// mid-sentence trigger plus sentence-ending punctuation was capitalised by
    /// the engine's own sentence split, not because it's a name. "I" and its
    /// contractions, and words with more than one capital (acronyms, "iOS",
    /// "McDonald"), are left alone. Whisper rarely emits this shape, so this is
    /// a no-op for most whisper output.
    private func lowercaseAfterMidSentenceTrigger(_ text: String, says: [String]) -> String {
        guard !says.isEmpty else { return text }
        let alternatives = says.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "\\b(?:\(alternatives))\\b\\s*[.?!]\\s+(\\p{Lu}[\\p{L}']*)",
            options: [.caseInsensitive]
        ) else { return text }
        let ns = text as NSString
        var result = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let range = match.range(at: 1)
            let word = ns.substring(with: range)
            let uppercaseCount = word.filter(\.isUppercase).count
            let isPronounI = word == "I" || word.hasPrefix("I'")
            guard uppercaseCount == 1, !isPronounI else { continue }
            result = result.replacingCharacters(in: range, with: word.prefix(1).lowercased() + word.dropFirst()) as NSString
        }
        return result as String
    }

    private func replace(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else {
            NSLog("[susurro] invalid rule pattern skipped: %@", pattern)
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
