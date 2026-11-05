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
    /// The end of a whole-buffer AX value with no readable cursor (Warp,
    /// Terminal), anchored on what Susurro last typed — see `BufferTail`.
    case bufferTail
    /// Nothing known: treated as an empty field (board decision 2).
    case none
}

/// What an Accessibility read of the focused field returned. Produced by the
/// app target's `FocusedFieldReader`; kept here so context resolution is testable.
public struct FieldRead: Sendable, Equatable {
    /// Text before the cursor (or the selection start). nil = unreadable.
    public var before: String?
    /// Text after the cursor (or the selection end). nil = unreadable.
    public var after: String?
    /// The focused element is a secure (password) field; nothing was read.
    public var secure: Bool
    /// Which read path produced this, plus lengths/positions only — never
    /// field text. For the per-app coverage log.
    public var detail: String
    /// The end of the field's value when the value is readable but the
    /// cursor is not (terminal buffers). Used only with the memory anchor.
    public var bufferTail: String?

    public init(before: String?, after: String? = nil, secure: Bool = false, detail: String = "",
                bufferTail: String? = nil) {
        self.before = before
        self.after = after
        self.secure = secure
        self.detail = detail
        self.bufferTail = bufferTail
    }

    /// Builds a read from a whole field value and its selection. Some apps
    /// (Gecko contenteditable inputs, e.g. Firefox/Zen) drop a trailing typed
    /// space from the reported value but keep the caret after it, so a caret
    /// past the end of the value means whitespace the value doesn't show.
    public static func fromValue(_ value: String, location: Int, length: Int) -> FieldRead {
        let ns = value as NSString
        let start = max(0, min(location, ns.length))
        let end = max(start, min(location + max(length, 0), ns.length))
        var before = ns.substring(to: start)
        if location > ns.length { before += " " }
        return FieldRead(before: before, after: ns.substring(from: end),
                         detail: "range valueLen=\(ns.length) caret=\(location)")
    }

    public static let secureField = FieldRead(before: nil, after: nil, secure: true, detail: "secure")
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

    /// Combines an Accessibility read with the self-tracked fallback.
    /// Accessibility wins whenever it produced a `before`; otherwise the
    /// memory tail (if Susurro typed into this same app last) is used; with
    /// neither, `before` is nil and the stage treats the field as empty.
    /// Secure input or a secure field never yields any context.
    public static func resolve(fieldRead: FieldRead?, memoryTail: String?,
                               pid: pid_t?, bundleID: String?, engine: EngineKind?,
                               secureInput: Bool) -> InsertContext {
        let secure = secureInput || (fieldRead?.secure ?? false)
        if secure {
            return InsertContext(before: nil, source: .none, pid: pid, bundleID: bundleID,
                                 engine: engine, secureInput: true)
        }
        if let read = fieldRead, let before = read.before {
            return InsertContext(before: before, after: read.after, source: .accessibility,
                                 pid: pid, bundleID: bundleID, engine: engine, secureInput: false)
        }
        if let buffer = fieldRead?.bufferTail, let memoryTail,
           let before = BufferTail.before(buffer: buffer, memoryTail: memoryTail) {
            return InsertContext(before: before, source: .bufferTail, pid: pid,
                                 bundleID: bundleID, engine: engine, secureInput: false)
        }
        if let memoryTail {
            return InsertContext(before: memoryTail, source: .selfTracked, pid: pid,
                                 bundleID: bundleID, engine: engine, secureInput: false)
        }
        return InsertContext(before: nil, source: .none, pid: pid, bundleID: bundleID,
                             engine: engine, secureInput: false)
    }

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

/// Board decision (BEA-648, Warp): when an app exposes its whole buffer but
/// not the cursor, treat the end of the buffer as the text before the cursor
/// if it still ends with what Susurro last typed, allowing for a few
/// characters of the user's own edits (a deleted full stop, a typed space).
/// Otherwise nil, and the memory fallback applies.
public enum BufferTail {
    /// Longest edit the user may have made after Susurro's text.
    static let maxUserEdit = 8
    /// Shortest prefix of the remembered tail that counts as an anchor.
    static let minAnchor = 4

    public static func before(buffer: String, memoryTail: String) -> String? {
        var buffer = Substring(buffer)
        while let last = buffer.last, last.isNewline { buffer = buffer.dropLast() }
        let tail = Array(memoryTail)
        guard !tail.isEmpty, !buffer.isEmpty else { return nil }
        let window = Array(buffer.suffix(tail.count + maxUserEdit))
        let minLen = min(minAnchor, tail.count)
        var length = tail.count
        while length >= minLen {
            let prefix = Array(tail[0..<length])
            // Last occurrence of the prefix in the window.
            if window.count >= length {
                var start = window.count - length
                while start >= 0 {
                    if Array(window[start..<start + length]) == prefix {
                        let edit = window[(start + length)...]
                        if edit.count <= maxUserEdit, !edit.contains(where: \.isNewline) {
                            return String(buffer)
                        }
                        break
                    }
                    start -= 1
                }
            }
            length -= 1
        }
        return nil
    }
}
