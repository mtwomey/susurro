import Foundation

/// Which foreground programs an iTerm2 latch may type into (BEA-700). Pure,
/// so it is unit-tested. The program is iTerm's per-session `jobName`
/// variable, read at pin time and again before every chunk.
///
/// v1 allows shells and AI agent CLIs only: in both, typed text sits on the
/// input line until the user presses Return (the codec never sends one).
/// Editors and ssh are refused on purpose (open decisions on BEA-700):
/// - vim/nvim normal mode turns words into commands, and the mode is not
///   visible from outside the terminal;
/// - over ssh the remote foreground program is invisible, so the check
///   above cannot be made at all.
public enum ITermProgram: Equatable, Sendable {
    case shell, agentCLI, editor, remote, other

    public var latchAllowed: Bool { self == .shell || self == .agentCLI }

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh"]
    /// Agent CLIs by process name. Confirmed live values go here; node-hosted
    /// agents that show up as plain `node` are NOT allowed (a bare node could
    /// be any program, e.g. a REPL that evaluates each line).
    static let agents: Set<String> = ["claude", "hermes", "codex", "gemini", "aider", "opencode"]
    static let editors: Set<String> = ["vim", "nvim", "vi", "view", "nano", "pico", "emacs", "micro", "helix", "hx", "kak", "joe", "ed"]
    static let remotes: Set<String> = ["ssh", "mosh", "mosh-client", "et", "telnet", "tmux", "screen"]

    /// Classifies a `jobName`. Login shells report a leading "-" ("-zsh");
    /// a path or a version suffix is stripped ("/bin/zsh", "python3.12").
    public static func classify(_ jobName: String) -> ITermProgram {
        var name = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("-") { name.removeFirst() }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        name = name.lowercased()
        if shells.contains(name) { return .shell }
        if agents.contains(name) { return .agentCLI }
        if editors.contains(name) || name.hasPrefix("emacs") { return .editor }
        if remotes.contains(name) { return .remote }
        return .other
    }

    /// The pill for a program latch refuses (pin time or mid-latch).
    public static func refusalPill(_ jobName: String) -> String {
        switch classify(jobName) {
        case .editor: return "Latch doesn't type into terminal editors yet — use it at a shell prompt or an AI agent"
        case .remote: return "Latch doesn't type into ssh or tmux sessions yet — the remote program can't be checked"
        default: return "Latch in iTerm works at a shell prompt or in an AI agent CLI (Claude Code, Hermes, Codex)"
        }
    }
}

/// The iTerm read-back (BEA-700): the text before the cursor on the cursor's
/// logical line, rebuilt from screen rows plus the cursor position. Pure.
///
/// A row that soft-wraps continues on the next row; the row that ends a
/// logical line has `hardEOL` set (the Python API's `hard_eol`). Cursor `x`
/// counts cells, so wide characters (CJK, most emoji) count as two.
public enum ITermScreen {
    public struct Row: Equatable, Sendable {
        public var text: String
        public var hardEOL: Bool
        public init(_ text: String, hardEOL: Bool) { self.text = text; self.hardEOL = hardEOL }
    }

    /// Text before the cursor on its logical line; nil if the cursor is off
    /// the given rows.
    public static func textBeforeCursor(rows: [Row], cursorX: Int, cursorY: Int) -> String? {
        guard cursorY >= 0, cursorY < rows.count, cursorX >= 0 else { return nil }
        var text = prefix(rows[cursorY].text, cells: cursorX)
        var y = cursorY - 1
        while y >= 0, !rows[y].hardEOL {
            text = rows[y].text + text
            y -= 1
        }
        return text
    }

    /// What the read-back reports for `chunk`: the chunk itself when the
    /// text before the cursor ends with it, else the same-length tail (a
    /// mismatch the delivery check rejects). Trailing spaces the terminal
    /// trims from a row are allowed for: a chunk ending in spaces matches
    /// when the cursor sits past them.
    public static func readBack(chunk: String, before: String) -> String {
        if before.hasSuffix(chunk) { return chunk }
        let trimmedChunk = String(chunk.reversed().drop(while: { $0 == " " }).reversed())
        let trimmedBefore = String(before.reversed().drop(while: { $0 == " " }).reversed())
        if !trimmedChunk.isEmpty, trimmedBefore.hasSuffix(trimmedChunk) { return chunk }
        return String(before.suffix(chunk.count))
    }

    /// The first `cells` terminal cells of `row`.
    static func prefix(_ row: String, cells: Int) -> String {
        var used = 0
        var out = ""
        for ch in row {
            let w = width(ch)
            if used + w > cells { break }
            used += w
            out.append(ch)
        }
        return out
    }

    /// Terminal cell width of a character: 2 for East Asian wide and emoji
    /// presentation, else 1 (an approximation of wcwidth).
    static func width(_ ch: Character) -> Int {
        guard let s = ch.unicodeScalars.first else { return 1 }
        if s.properties.isEmojiPresentation { return 2 }
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default: return 1
        }
    }
}
