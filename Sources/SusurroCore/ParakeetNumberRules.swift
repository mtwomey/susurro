import Foundation

/// Parakeet-only number formatting (BEA-646).
///
/// Parakeet TDT decides on every decode whether to write a number as digits or
/// as words (its training labels mix both). Long dictations, and sentences that
/// are followed by more speech, often come out spelled out ("nine forty five
/// AM", "january twenty second", "three per cent"). These rules rewrite only
/// spans with an unambiguous clue — AM/PM, a month name followed by an ordinal,
/// or "percent" — so ordinary words ("no one", "we may first", "at nine") are
/// left alone. Text that is already formatted passes through unchanged.
public enum ParakeetNumberRules {
    static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]
    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30,
    ]
    /// "may" is excluded here: lowercase "may" is almost always the verb.
    static let months = ["january", "february", "march", "april", "june", "july", "august",
                         "september", "october", "november", "december"]

    static let unitWords = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
    static let digitWords = "one|two|three|four|five|six|seven|eight|nine"
    static let tensWords = "twenty|thirty|forty|fifty"
    static let firstNineOrdinals = "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth"
    static let ordinalWords = "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth|thirtieth"
    static var number: String { "(?:(?:\(tensWords))(?:[- ](?:\(digitWords)))?|\(unitWords))" }

    public static func apply(_ text: String) -> String {
        var t = text
        // 1. Spelled-out clock times with AM/PM: "nine forty five AM" -> "9:45 a.m."
        t = sub(t, "\\b(\(unitWords))(?:[: ]+(\(number)))?\\s+(A\\.?M\\.?|P\\.?M\\.?)(\\W|$)", ci: true) { g in
            let h = value(g[1]!), m = g[2].map(value) ?? 0
            guard (1...12).contains(h), m <= 59 else { return nil }
            let ap = g[3]!.lowercased().hasPrefix("a") ? "a.m." : "p.m."
            return (g[2] != nil ? "\(h):\(String(format: "%02d", m)) \(ap)" : "\(h) \(ap)") + (g[4] ?? "")
        }
        // 2. Digit times with AM/PM written as "AM"/"A.M.": "11 A.M." -> "11 a.m."
        t = sub(t, "\\b(\\d{1,2}(?::\\d\\d)?) (A\\.M\\.|AM|P\\.M\\.|PM)(?=\\W|$)", ci: false) { g in
            "\(g[1]!) \(g[2]!.hasPrefix("A") ? "a.m." : "p.m.")"
        }
        // 3. Month + spelled ordinal: "january twenty second" -> "January 22nd"
        let monthAlt = "(?i:\(months.joined(separator: "|")))|May"
        t = sub(t, "\\b(\(monthAlt))\\s+((?i:(?:twenty|thirty)[- ](?:\(firstNineOrdinals))|\(ordinalWords)))\\b", ci: false) { g in
            let n = ordinalValue(g[2]!)
            return "\(capitalized(g[1]!)) \(n)\(suffix(n))"
        }
        // 4. Month + digits: "march 3rd" -> "March 3rd"
        t = sub(t, "\\b((?i:\(months.joined(separator: "|"))))\\s+(\\d{1,2}(?:st|nd|rd|th)?)\\b", ci: false) { g in
            "\(capitalized(g[1]!)) \(g[2]!)"
        }
        // 5. Percent: "three per cent" -> "3%"
        t = sub(t, "\\b(\(number))\\s+(?:percent|per cent)\\b", ci: true) { g in "\(value(g[1]!))%" }
        return t
    }

    static func value(_ words: String) -> Int {
        words.lowercased().split(whereSeparator: { $0 == "-" || $0 == " " })
            .reduce(0) { $0 + (tens[String($1)] ?? 0) + (units[String($1)] ?? 0) }
    }

    static func ordinalValue(_ words: String) -> Int {
        let parts = words.lowercased().split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init)
        if parts.count == 1 { return ordinals[parts[0]] ?? 0 }
        return (tens[parts[0]] ?? 0) + (ordinals[parts[1]] ?? 0)
    }

    static func suffix(_ n: Int) -> String {
        if (10...20).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst().lowercased() }

    /// Regex replace with a closure; returning nil keeps the original match.
    static func sub(_ text: String, _ pattern: String, ci: Bool, _ f: ([String?]) -> String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []) else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let groups: [String?] = (0..<m.numberOfRanges).map {
                let r = m.range(at: $0); return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(groups) ?? groups[0]!
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
