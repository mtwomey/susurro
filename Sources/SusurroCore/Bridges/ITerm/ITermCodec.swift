import Foundation

/// AppleScript for a possible iTerm2 latch bridge (BEA-695). Pure, so it is
/// unit-tested. **Not a bridge and not registered:** iTerm fails the
/// read-back criterion (docs/BRIDGES.md "Further bridges"), so latch must not
/// engage there. This file keeps the one safe delivery shape on record so a
/// later bridge cannot regress to interpolating text into script source.
///
/// Rules encoded here:
/// - The script source is fixed. Dictated text and the session id travel as
///   `osascript` argv items (`on run argv`), never inside the source, so no
///   escaping is needed and dictated text can never become AppleScript.
/// - `write text … newline no`: iTerm's default appends a newline, which
///   would *execute* the line in a shell. Terminal.app has no equivalent
///   (`do script` always runs the text as a command), so it gets no codec.
/// - The session is addressed by its `id` (pinned at latch time), never by
///   "current session", which follows the user's focus.
public enum ITermScript {
    public static let bundleID = "com.googlecode.iterm2"

    /// Writes argv item 2 into the session whose id is argv item 1, with no
    /// newline. Returns "ok", or "gone" when the session no longer exists.
    public static let write = """
    on run argv
    set sid to item 1 of argv
    set t to item 2 of argv
    tell application id "com.googlecode.iterm2"
    repeat with w in windows
    repeat with tb in tabs of w
    repeat with s in sessions of tb
    if (id of s) is sid then
    tell s to write text t newline no
    return "ok"
    end if
    end repeat
    end repeat
    end repeat
    end tell
    return "gone"
    end run
    """

    /// Session ids are UUID-shaped; anything else is refused before spawning.
    public static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == ":"
        }
    }

    /// `osascript` arguments for one write, or nil for an invalid session id
    /// or text containing a newline/carriage return (it would execute).
    public static func writeArguments(sessionID: String, text: String) -> [String]? {
        guard isValidSessionID(sessionID),
              !text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return nil }
        return ["-e", write, "--", sessionID, text]
    }
}
