import Foundation

extension BridgeID {
    /// iTerm2 session pinned by id; AppleScript `write text … newline no`.
    public static let itermSession = BridgeID(rawValue: "itermSession")
}

extension ITermScript {
    /// The frontmost window's current session, at pin time only (iTerm is
    /// frontmost then, so this is the session the user is looking at).
    /// Replies "<id>\n<jobName>", or "none".
    public static let current = """
    tell application id "com.googlecode.iterm2"
    if (count of windows) is 0 then return "none"
    set s to current session of current window
    tell s to set j to (variable named "jobName")
    return (id of s) & linefeed & j
    end tell
    """

    /// Session argv item 1: "alive\n<jobName>" or "gone".
    public static let status = """
    on run argv
    set sid to item 1 of argv
    tell application id "com.googlecode.iterm2"
    repeat with w in windows
    repeat with tb in tabs of w
    repeat with s in sessions of tb
    if (id of s) is sid then
    tell s to set j to (variable named "jobName")
    return "alive" & linefeed & j
    end if
    end repeat
    end repeat
    end repeat
    end tell
    return "gone"
    end run
    """

    public static func statusArguments(sessionID: String) -> [String]? {
        isValidSessionID(sessionID) ? ["-e", status, "--", sessionID] : nil
    }

    /// Parses `current`: (session id, jobName), nil for "none"/garbage.
    public static func parseCurrent(_ reply: String) -> (id: String, job: String)? {
        let parts = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, isValidSessionID(String(parts[0])) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    public enum SessionStatus: Equatable, Sendable { case alive(job: String), gone }

    public static func parseStatus(_ reply: String) -> SessionStatus? {
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if r == "gone" { return .gone }
        let parts = r.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "alive" else { return nil }
        return .alive(job: String(parts[1]))
    }
}

/// Runs iTerm AppleScript; injectable so the bridge is tested without iTerm.
public protocol ITermScripting: Sendable {
    /// stdout of `osascript <arguments>`, nil on failure/timeout.
    func run(_ arguments: [String]) -> String?
}

public struct OSAScriptRunner: ITermScripting {
    public var timeout: TimeInterval = 3
    public init() {}
    public func run(_ arguments: [String]) -> String? {
        guard let out = ProcessRunner().run("/usr/bin/osascript", arguments, timeout: timeout), out.status == 0 else { return nil }
        return out.stdout
    }
}

/// The read-back source: the pinned session's screen rows + cursor. The
/// Python API (`async_get_screen_contents` + cursor, with `hard_eol`) is the
/// intended implementation; until it exists the bridge has none and every
/// insert fails closed (clipboard + pill), so latch never types blind.
public protocol ITermScreenReading: Sendable {
    /// nil = can't read (API off, timeout); `.gone` handled by status.
    func screen(sessionID: String) -> (rows: [ITermScreen.Row], cursorX: Int, cursorY: Int)?
}

/// iTerm2 latch bridge (BEA-700). Not in the bundled allowlist: it engages
/// only once a read-back source exists and the live suite passes.
public struct ITermBridge: LatchingBridge {
    public let id = BridgeID.itermSession
    public let bundleIDs: Set<String> = [ITermScript.bundleID]
    public let documentNoun = "session"
    public var scripting: any ITermScripting
    public var screen: (any ITermScreenReading)?

    public init(scripting: any ITermScripting = OSAScriptRunner(), screen: (any ITermScreenReading)? = nil) {
        self.scripting = scripting
        self.screen = screen
    }

    public func pin(_ request: LatchPinRequest) throws(BridgeError) -> any LatchTarget {
        guard let reply = scripting.run(["-e", ITermScript.current]) else { throw .notRunning }
        guard let (sid, job) = ITermScript.parseCurrent(reply) else { throw .noTarget }
        guard ITermProgram.classify(job).latchAllowed else { throw .noTarget }
        guard let screen else { throw .notEnabled }
        let pin = LatchPin(method: id, bundleID: request.bundleID, appName: request.appName,
                           documentName: job, handle: sid, documentNoun: documentNoun)
        return ITermLatchTarget(pin: pin, sessionID: sid, jobName: job, scripting: scripting, screen: screen)
    }

    public func refusalPill(for error: BridgeError) -> String? {
        switch error {
        case .notEnabled: return "Turn on iTerm2's Python API (Settings → General → Magic) to latch into iTerm"
        case .noTarget: return ITermProgram.refusalPill("")
        default: return nil
        }
    }
}

/// A latched iTerm session. Before every chunk: the session is alive and
/// its foreground program is the one pinned (and still allowed); otherwise
/// `.gone`, which ends the latch with the text on the clipboard.
public final class ITermLatchTarget: LatchTarget {
    public let pin: LatchPin
    let sessionID: String
    let jobName: String
    private let scripting: any ITermScripting
    private let screen: any ITermScreenReading

    init(pin: LatchPin, sessionID: String, jobName: String, scripting: any ITermScripting, screen: any ITermScreenReading) {
        self.pin = pin
        self.sessionID = sessionID
        self.jobName = jobName
        self.scripting = scripting
        self.screen = screen
    }

    /// nil = fine; else the reply that stops this chunk.
    func precheck() -> LatchBridgeReply? {
        guard let args = ITermScript.statusArguments(sessionID: sessionID),
              let raw = scripting.run(args), let status = ITermScript.parseStatus(raw) else { return .unavailable }
        switch status {
        case .gone: return .gone
        case .alive(let job):
            return job == jobName && ITermProgram.classify(job).latchAllowed ? nil : .gone
        }
    }

    private func before() -> LatchBridgeReply {
        guard let s = screen.screen(sessionID: sessionID),
              let text = ITermScreen.textBeforeCursor(rows: s.rows, cursorX: s.cursorX, cursorY: s.cursorY) else { return .unavailable }
        return .value(text)
    }

    public func context() -> LatchBridgeReply {
        if let stop = precheck() { return stop }
        return before()
    }

    public func insert(_ text: String) -> LatchBridgeReply {
        guard let args = ITermScript.writeArguments(sessionID: sessionID, text: text) else { return .unavailable }
        if let stop = precheck() { return stop }
        guard let raw = scripting.run(args) else { return .unavailable }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) == "gone" { return .gone }
        guard case .value(let line) = before() else { return .unavailable }
        return .value(ITermScreen.readBack(chunk: text, before: line))
    }

    /// Nothing is left inside iTerm by a pin.
    public func release() {}
}
