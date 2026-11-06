import Foundation

// Emacs bridge codec (docs/BRIDGES.md): everything Susurro *says* to Emacs
// and how it reads the answers. Pure, so it is unit-tested. Dictated text is
// only ever passed base64-encoded, never interpolated into Lisp.

public enum EmacsBridgeInfo {
    public static let bundleID = "org.gnu.Emacs"
}

/// The Emacs server's line protocol (what emacsclient speaks).
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
        guard let value = printedString(reply: reply),
              value != "SKIP", let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }


    /// The printed Lisp string from a `-print` reply, quotes removed (the
    /// latch bridge also needs the sentinels SKIP and GONE).
    public static func printedString(reply: String) -> String? {
        guard let line = reply.split(separator: "\n").first(where: { $0.hasPrefix("-print ") }) else { return nil }
        // The printed value ends with a newline, sent quoted as "&n".
        let value = unquote(String(line.dropFirst("-print ".count))).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
        return String(value.dropFirst().dropLast())
    }
}

/// Lisp for the context read during ordinary dictation: text before point in
/// the selected window, never the minibuffer (where Emacs reads passwords).
public enum EmacsReadLisp {
    public static func textBeforeCursor(maxChars: Int = 200) -> String {
        """
        (let* ((w (selected-window)) (b (window-buffer w))) \
        (if (minibufferp b) "SKIP" \
        (with-current-buffer b (let ((p (window-point w))) \
        (base64-encode-string (encode-coding-string \
        (buffer-substring-no-properties (max (point-min) (- p \(maxChars))) p) 'utf-8) t)))))
        """
    }
}

/// Emacs Lisp for the Emacs latch (pure, so it is unit-tested). Text is
/// always passed base64-encoded, never interpolated raw. The marker has
/// insertion type t, so it advances past each insert and tracks the user's
/// edits elsewhere in the buffer.
public enum EmacsLatchLisp {
    /// Marker variable names are generated here, never from user input.
    public static func markerSymbol(_ id: Int) -> String { "susurro--latch-\(id)" }

    /// Pin the selected window's buffer at its point. Replies base64 of
    /// "<buffer name>", or SKIP for the minibuffer.
    public static func pin(id: Int) -> String {
        let sym = markerSymbol(id)
        return """
        (let* ((w (selected-window)) (b (window-buffer w))) \
        (if (minibufferp b) "SKIP" \
        (progn (defvar \(sym) nil) \
        (setq \(sym) (with-current-buffer b (copy-marker (window-point w) t))) \
        (base64-encode-string (encode-coding-string (buffer-name b) 'utf-8) t))))
        """
    }

    /// Context before the marker; GONE if the buffer died.
    public static func context(id: Int, maxChars: Int = 200) -> String {
        let sym = markerSymbol(id)
        return """
        (let ((m (and (boundp '\(sym)) \(sym)))) \
        (if (and (markerp m) (buffer-live-p (marker-buffer m))) \
        (with-current-buffer (marker-buffer m) \
        (base64-encode-string (encode-coding-string \
        (buffer-substring-no-properties (max (point-min) (- m \(maxChars))) m) 'utf-8) t)) "GONE"))
        """
    }

    /// Insert `text` at the marker. Replies base64 of the text now between
    /// the old and new marker position (the read-back), or GONE.
    public static func insert(id: Int, text: String) -> String {
        let sym = markerSymbol(id)
        let b64 = Data(text.utf8).base64EncodedString()
        return """
        (let ((m (and (boundp '\(sym)) \(sym)))) \
        (if (and (markerp m) (buffer-live-p (marker-buffer m))) \
        (with-current-buffer (marker-buffer m) \
        (let ((p (marker-position m)) \
        (txt (decode-coding-string (base64-decode-string "\(b64)") 'utf-8))) \
        (save-excursion (goto-char m) (insert txt)) \
        (base64-encode-string (encode-coding-string \
        (buffer-substring-no-properties p m) 'utf-8) t))) "GONE"))
        """
    }

    public enum Reply: Sendable, Equatable {
        case value(String)
        /// The buffer or marker is gone.
        case gone
        /// Minibuffer: never latch there.
        case skip
        /// No usable reply (server down, timeout, error).
        case none
    }

    public static func decode(reply: String?) -> Reply {
        guard let reply, let printed = EmacsServerProtocol.printedString(reply: reply) else { return .none }
        if printed == "GONE" { return .gone }
        if printed == "SKIP" { return .skip }
        guard let data = Data(base64Encoded: printed), let text = String(data: data, encoding: .utf8) else { return .none }
        return .value(text)
    }

    /// Release the marker when latch ends.
    public static func release(id: Int) -> String {
        let sym = markerSymbol(id)
        return """
        (progn (when (and (boundp '\(sym)) (markerp \(sym))) (set-marker \(sym) nil)) \
        (makunbound '\(sym)) (base64-encode-string "OK" t))
        """
    }
}
