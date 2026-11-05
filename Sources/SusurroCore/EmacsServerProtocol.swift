import Foundation

/// The Emacs server's line protocol (what emacsclient speaks), for the app
/// target's Emacs bridge. Pure, so it is unit-tested here.
public enum EmacsServerProtocol {
    public static func quote(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&&")
            .replacingOccurrences(of: "\n", with: "&n")
            .replacingOccurrences(of: " ", with: "&_")
        if out.hasPrefix("-") { out = "&" + out }
        return out
    }

    public static func unquote(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "&", let n = it.next() else { out.append(c); continue }
            switch n {
            case "_": out.append(" ")
            case "n": out.append("\n")
            default: out.append(n)   // "&&" -> "&", "&-" -> "-"
            }
        }
        return out
    }

    /// Parses the server's reply; nil unless it carries a base64 answer.
    public static func parse(reply: String) -> String? {
        guard let line = reply.split(separator: "\n").first(where: { $0.hasPrefix("-print ") }) else { return nil }
        // The printed value ends with a newline, sent quoted as "&n".
        var value = unquote(String(line.dropFirst("-print ".count))).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
        value = String(value.dropFirst().dropLast())
        guard value != "SKIP", let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

}
