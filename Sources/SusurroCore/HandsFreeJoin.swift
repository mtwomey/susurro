import Foundation

/// Hands-free joins (BEA-657): each pause-cut chunk is transcribed on its own,
/// so the engine closes every chunk with an end mark. The chunk's final mark
/// is held back; when the next chunk arrives, a joint clip (A's last speech,
/// the real pause, B's speech) is transcribed and only the punctuation at the
/// join is read from it. The words typed are always the per-chunk words.
public enum HandsFreeJoin {
    public static let endMarks: Set<Character> = [".", "?", "!"]

    // MARK: - Held mark

    /// Split a chunk's text into the part to type now and its final end mark.
    /// Only a single trailing . ? or ! is held; "..." and text without a mark
    /// are returned unchanged with no mark.
    public static func holdMark(_ text: String) -> (body: String, mark: Character?) {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last, endMarks.contains(last) else { return (text, nil) }
        let rest = trimmed.dropLast()
        if let prev = rest.last, endMarks.contains(prev) { return (text, nil) } // "...", "?!"
        guard rest.contains(where: { $0.isLetter || $0.isNumber }) else { return (text, nil) }
        return (String(rest), last)
    }

    // MARK: - Join decision

    public enum Decision: Equatable, Sendable {
        /// The joint transcript ends a sentence at the join: keep the mark.
        case sentenceBreak
        /// No end mark at the join: drop the held mark, continue lower-case.
        case continuation
        /// A's ending could not be found in the joint text: use A's own mark.
        case unmatched
    }

    struct Token { let norm: String; let trailing: String; var startsLower = false }

    static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let norm = String(raw.lowercased().filter { $0.isLetter || $0.isNumber })
            guard !norm.isEmpty else { return nil }
            // Punctuation after the last letter/digit of the token.
            var trailing = ""
            for ch in raw.reversed() {
                if ch.isLetter || ch.isNumber { break }
                trailing.insert(ch, at: trailing.startIndex)
            }
            let firstLetter = raw.first(where: { $0.isLetter })
            return Token(norm: norm, trailing: trailing, startsLower: firstLetter?.isLowercase ?? false)
        }
    }

    /// Decide the join by locating A's last words (`previousBody`, the text
    /// typed for A) in `jointText`. The joint clip starts ~3 s back in A, so
    /// its first word may be cut mid-word; matching uses A's last 3, then 2,
    /// then 1 words, and a word only needs to match as a suffix when it is
    /// the first word of the joint text.
    public static func decide(previousBody: String, jointText: String) -> Decision {
        let a = tokens(previousBody)
        let j = tokens(jointText)
        guard !a.isEmpty, !j.isEmpty else { return .unmatched }
        for k in stride(from: min(3, a.count), through: 1, by: -1) {
            let tail = a.suffix(k).map(\.norm)
            if k == 1 && tail[0].count < 3 && a.count > 1 { continue } // too weak alone
            guard j.count >= k else { continue }
            for start in 0...(j.count - k) {
                var ok = true
                for i in 0..<k {
                    let jw = j[start + i].norm, aw = tail[i]
                    let matches = jw == aw || (start + i == 0 && i == 0 && jw.count >= 2 && aw.hasSuffix(jw))
                    if !matches { ok = false; break }
                }
                guard ok else { continue }
                let end = j[start + k - 1]
                // Nothing of B in the joint text: no evidence either way.
                guard start + k < j.count else { return .unmatched }
                guard end.trailing.contains(where: { endMarks.contains($0) }) else { return .continuation }
                // "3:30 p.m. on Friday": a period followed by a lower-case
                // word is an abbreviation, not a sentence end.
                if !end.trailing.contains(where: { $0 == "?" || $0 == "!" }), j[start + k].startsLower {
                    return .continuation
                }
                return .sentenceBreak
            }
        }
        return .unmatched
    }

    /// The text to type for chunk B after A's held `mark`, given the join
    /// decision. `next` is B's body (its own final mark already held back).
    /// Sentence break / unmatched: "<mark> " + B unchanged. Continuation:
    /// " " + B with its first word lower-cased (ContinuationCase rules: "I",
    /// "I'm" and acronyms keep their case).
    public static func joined(mark: Character, decision: Decision, next: String) -> String {
        let body = next.drop(while: { $0.isWhitespace })
        switch decision {
        case .sentenceBreak, .unmatched:
            return String(mark) + " " + body
        case .continuation:
            // Mid-sentence context: the previous chunk ends without a mark.
            let ctx = InsertContext(before: "x", source: .selfTracked)
            return " " + ContinuationCase().apply(String(body), ctx)
        }
    }

    // MARK: - Joint clip

    /// Build the joint clip. Indices are relative to each chunk.
    /// - aLastSpeechEnd: end of A's last speech frame within `a`.
    /// - bFirstSpeechStart: start of B's first speech frame within `b`.
    /// The pause is the real audio between them (A's trailing part + B's
    /// leading part); when longer than `maxPause` its middle is removed.
    public static func jointClip(a: [Float], aLastSpeechEnd: Int, b: [Float], bFirstSpeechStart: Int,
                                 sampleRate: Int = 16_000, tailSeconds: Double = 3,
                                 maxPause: Double = 2) -> [Float] {
        let aEnd = max(0, min(aLastSpeechEnd, a.count))
        let bStart = max(0, min(bFirstSpeechStart, b.count))
        let tailStart = max(0, aEnd - Int(tailSeconds * Double(sampleRate)))
        var pause = Array(a[aEnd...]) + Array(b[..<bStart])
        let cap = Int(maxPause * Double(sampleRate))
        if pause.count > cap {
            let half = cap / 2
            pause = Array(pause.prefix(half)) + Array(pause.suffix(cap - half))
        }
        return Array(a[tailStart..<aEnd]) + pause + Array(b[bStart...])
    }
}

/// The held-mark state for one hands-free session. Pure; the app feeds it
/// chunk results and session events and types what it returns.
public struct HeldMarkJoiner: Sendable {
    public struct Held: Sendable, Equatable {
        public let mark: Character
        /// The text typed for the chunk (without the mark), for matching.
        public let body: String
        public let pid: Int32?
    }

    public private(set) var held: Held?
    public init() {}

    /// What to do with a finished chunk.
    public enum Plan: Equatable, Sendable {
        /// First chunk (nothing held): type `text` as a normal dictation.
        case fresh(text: String)
        /// A mark is held: a joint transcript is needed to decide the join;
        /// then call `resolve(decision:next:)`.
        case needsJoin(held: Held, next: String)
    }

    /// Accept chunk B's per-chunk text. Its final mark is held back.
    public mutating func accept(_ text: String, pid: Int32?) -> Plan {
        let (body, mark) = HandsFreeJoin.holdMark(text)
        let previous = held
        held = mark.map { Held(mark: $0, body: Self.lastWords(body), pid: pid) }
        if let previous, previous.pid == pid {
            return .needsJoin(held: previous, next: body)
        }
        // Different app (or nothing held): never join across apps.
        return .fresh(text: body)
    }

    /// Text to type once the join is decided.
    public func resolve(previous: Held, decision: HandsFreeJoin.Decision, next: String) -> String {
        HandsFreeJoin.joined(mark: previous.mark, decision: decision, next: next)
    }

    /// Session stopped (tap / auto-stop): the held mark to type, if any.
    public mutating func stop() -> Character? {
        defer { held = nil }
        return held?.mark
    }

    /// Esc / discard: drop the held mark.
    public mutating func discard() { held = nil }

    /// Fallback (cursor moved, field changed, app switched): release the
    /// held mark now so it lands at the original spot; returns it.
    public mutating func flush() -> Character? { stop() }

    /// Keep only the last few words of a body (all the matcher needs).
    static func lastWords(_ text: String, count: Int = 6) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).suffix(count).joined(separator: " ")
    }
}
