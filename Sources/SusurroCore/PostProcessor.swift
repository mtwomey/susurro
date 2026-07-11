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
        var isEnabled: Bool { enabled ?? true }
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

    public func process(_ text: String) -> String {
        guard let rules = loadRules() else { return text }
        var result = text

        let enabledPunctuation = rules.punctuation.filter(\.isEnabled)

        // 1. Strip stray commas/periods that whisper places around trigger words:
        //    "quote, wow, end quote." -> "quote wow end quote"
        var keywords: [String] = []
        if rules.options.pairQuotes { keywords += ["quote", "end quote"] }
        keywords += enabledPunctuation.map(\.say)
        for keyword in keywords {
            let escaped = NSRegularExpression.escapedPattern(for: keyword)
            result = replace(in: result,
                             pattern: "[,.]?\\s*\\b(\(escaped))\\b\\s*[,.]?",
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
            // "word ." -> "word.", "word , word" -> "word, word"
            result = replace(in: result, pattern: "[ \\t]+([,.?!])", template: "$1")
        }

        // 7. Capitalize a sentence-start-like string
        if rules.options.autoCapitalize, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
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
