import AppKit
import ApplicationServices
import Foundation
import SusurroCore

/// Per-app bridges: the last-resort way to get the text before the cursor
/// from an app whose Accessibility data is unusable, by asking the app
/// itself. Looked up by bundle ID, so other apps pay nothing. A bridge
/// returns nil whenever it can't answer quickly; the generic providers then
/// apply. Must never return secure input.
protocol AppBridge: Sendable {
    var name: String { get }
    var bundleIDs: Set<String> { get }
    /// Blocking; called off the main thread inside the 250 ms read cap.
    func textBeforeCursor() -> String?
}

enum AppBridges {
    static let all: [any AppBridge] = [EmacsServerBridge()]

    static func bridge(for bundleID: String?) -> (any AppBridge)? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleIDs.contains(bundleID) }
    }
}

/// Emacs 30's NS port publishes a stale, NUL-padded buffer copy to
/// Accessibility (docs/TEXT_HANDLING_FINDINGS.md §6.1), so ask the running
/// Emacs server instead: one request on its Unix socket (the protocol
/// emacsclient speaks), ~2-35 ms measured, no process spawned. Nothing
/// happens unless the server is running (`M-x server-start`). The minibuffer
/// is never read — that is where Emacs reads passwords.
struct EmacsServerBridge: AppBridge {
    let name = "emacs"
    let bundleIDs: Set<String> = [EmacsBridgeInfo.bundleID]
    var timeout: TimeInterval = 0.15
    var maxChars = 200

    private var expression: String { EmacsReadLisp.textBeforeCursor(maxChars: maxChars) }

    func socketPath() -> String? {
        var candidates: [String] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] {
            candidates.append(xdg + "/emacs/server")
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 {
            let tmp = String(cString: buf)
            candidates.append((tmp.hasSuffix("/") ? tmp : tmp + "/") + "emacs\(getuid())/server")
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func textBeforeCursor() -> String? {
        rawEval(expression).flatMap(EmacsServerProtocol.parse(reply:))
    }

    // MARK: Latch (BEA-691)

    /// Pin the selected window's buffer at point with a marker. nil when the
    /// server is down or the minibuffer is selected.
    func latchPin(id: Int, appName: String) -> LatchPin? {
        guard case .value(let bufferName) = EmacsLatchLisp.decode(reply: rawEval(EmacsLatchLisp.pin(id: id), timeout: 0.5))
        else { return nil }
        return LatchPin(method: .emacsServer, bundleID: EmacsBridgeInfo.bundleID, appName: appName,
                        documentName: bufferName, handle: String(id))
    }

    func latchContext(_ pin: LatchPin) -> EmacsLatchLisp.Reply {
        guard let id = Int(pin.handle) else { return .none }
        return EmacsLatchLisp.decode(reply: rawEval(EmacsLatchLisp.context(id: id), timeout: 0.5))
    }

    func latchInsert(_ text: String, at pin: LatchPin) -> EmacsLatchLisp.Reply {
        guard let id = Int(pin.handle) else { return .none }
        return EmacsLatchLisp.decode(reply: rawEval(EmacsLatchLisp.insert(id: id, text: text), timeout: 1.0))
    }

    func latchRelease(_ pin: LatchPin) {
        guard let id = Int(pin.handle) else { return }
        _ = rawEval(EmacsLatchLisp.release(id: id), timeout: 0.5)
    }

    /// One `-eval` request on the server socket; the raw reply text.
    private func rawEval(_ lisp: String, timeout: TimeInterval? = nil) -> String? {
        let timeout = timeout ?? self.timeout
        guard let path = socketPath() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let request = Array(("-eval " + EmacsServerProtocol.quote(lisp) + "\n").utf8)
        guard request.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == request.count else { return nil }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            reply.append(contentsOf: chunk[0..<n])
            if let text = String(data: reply, encoding: .utf8),
               EmacsServerProtocol.printedString(reply: text) != nil || text.contains("-error ") {
                return text
            }
        }
        return String(data: reply, encoding: .utf8)
    }
}

/// A latched Emacs buffer: the marker pinned by `EmacsServerBridge.latchPin`.
final class EmacsLatchTarget: LatchTarget, @unchecked Sendable {
    let pin: LatchPin
    private let bridge: EmacsServerBridge

    init(pin: LatchPin, bridge: EmacsServerBridge) {
        self.pin = pin
        self.bridge = bridge
    }

    private static func map(_ reply: EmacsLatchLisp.Reply) -> LatchBridgeReply {
        switch reply {
        case .value(let s): return .value(s)
        case .gone: return .gone
        case .skip, .none: return .unavailable
        }
    }

    func context() -> LatchBridgeReply { Self.map(bridge.latchContext(pin)) }
    func insert(_ text: String) -> LatchBridgeReply { Self.map(bridge.latchInsert(text, at: pin)) }
    func release() { bridge.latchRelease(pin) }
}

/// Obsidian through its official CLI (`obsidian eval`), BEA-691. Each call
/// spawns the CLI (~60 ms `version`, ~150 ms eval measured) with arguments
/// passed directly (no shell). The socket (`~/.obsidian-cli.sock`) is not
/// used: its protocol is undocumented and the CLI is fast enough per chunk.
struct ObsidianCLI: Sendable {
    var path = "/usr/local/bin/obsidian"
    var timeout: TimeInterval = 3

    func run(_ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    func eval(_ js: String) -> ObsidianLatchJS.Reply? {
        run(["eval", "code=" + js]).flatMap(ObsidianLatchJS.decode)
    }

    /// The app version from the CLI (not the bundle short version); nil
    /// when the CLI is missing or disabled.
    func appVersion() -> [Int]? { run(["version"]).flatMap(ObsidianLatchJS.appVersion) }
}

final class ObsidianLatchTarget: LatchTarget, @unchecked Sendable {
    let pin: LatchPin
    private let cli: ObsidianCLI
    private let id: Int

    init(pin: LatchPin, cli: ObsidianCLI, id: Int) {
        self.pin = pin
        self.cli = cli
        self.id = id
    }

    private static func map(_ reply: ObsidianLatchJS.Reply?, _ value: (ObsidianLatchJS.Reply) -> String?) -> LatchBridgeReply {
        guard let reply else { return .unavailable }
        if reply.gone == true { return .gone }
        return value(reply).map { .value($0) } ?? .unavailable
    }

    func context() -> LatchBridgeReply { Self.map(cli.eval(ObsidianLatchJS.context(id: id))) { $0.ctx } }
    func insert(_ text: String) -> LatchBridgeReply {
        Self.map(cli.eval(ObsidianLatchJS.insert(id: id, text: text))) { $0.back }
    }
    func release() { _ = cli.eval(ObsidianLatchJS.release(id: id)) }
}

/// TextEdit latch through Accessibility (BEA-691): `kAXSelectedText` write on
/// the element focused at latch time, re-validated before each chunk, read
/// back from the value. NOT on the bundled allowlist: it is enabled only if
/// the in-app undo check passes (needs Matthew's go-ahead; it takes focus).
final class AXSelectedTextLatchTarget: LatchTarget, @unchecked Sendable {
    let pin: LatchPin
    private let element: AXUIElement
    private let pid: pid_t

    init?(pid: pid_t, bundleID: String, appName: String) {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard Self.string(element, kAXRoleAttribute) == kAXTextAreaRole as String else { return nil }
        var window: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window)
        let title = window.flatMap { w in CFGetTypeID(w) == AXUIElementGetTypeID() ? Self.string(w as! AXUIElement, kAXTitleAttribute) : nil }
        self.element = element
        self.pid = pid
        self.pin = LatchPin(method: .axSelectedText, bundleID: bundleID, appName: appName,
                            documentName: title ?? "document", handle: String(pid))
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func selection() -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Re-validate: same process, still a text area with a window.
    private func alive() -> Bool {
        var p: pid_t = 0
        guard AXUIElementGetPid(element, &p) == .success, p == pid,
              Self.string(element, kAXRoleAttribute) == kAXTextAreaRole as String else { return false }
        var window: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success
    }

    func context() -> LatchBridgeReply {
        guard alive() else { return .gone }
        guard let value = Self.string(element, kAXValueAttribute), let sel = selection() else { return .unavailable }
        let ns = value as NSString
        let start = max(0, min(sel.location, ns.length) - 200)
        return .value(ns.substring(with: NSRange(location: start, length: min(sel.location, ns.length) - start)))
    }

    func insert(_ text: String) -> LatchBridgeReply {
        guard alive() else { return .gone }
        guard let sel = selection(),
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
              let value = Self.string(element, kAXValueAttribute) else { return .unavailable }
        let ns = value as NSString
        let len = (text as NSString).length
        guard sel.location + len <= ns.length else { return .value("") }
        return .value(ns.substring(with: NSRange(location: sel.location, length: len)))
    }

    func release() {}
}

enum LatchPinResult {
    case pinned(any LatchTarget)
    case refused(pill: String)
}

@MainActor
enum LatchTargets {
    private static var nextID = Int(Date().timeIntervalSince1970) % 100_000
    /// Pin the frontmost app's target if it is on the bundled allowlist and
    /// its bridge can pin right now; otherwise refuse with the pill to show
    /// (the session stays hands-free). Blocks briefly (socket/CLI).
    static func pin(bundleID: String?, appName: String) -> LatchPinResult {
        let notSupported = LatchPinResult.refused(pill: LatchDelivery.notSupportedPill(appName: appName))
        nextID += 1
        switch LatchAllowlist.bundled.method(for: bundleID) {
        case .emacsServer?:
            let bridge = EmacsServerBridge()
            guard let pin = bridge.latchPin(id: nextID, appName: appName) else { return notSupported }
            return .pinned(EmacsLatchTarget(pin: pin, bridge: bridge))
        case .obsidianCLI?:
            let cli = ObsidianCLI()
            guard let version = cli.appVersion() else { return .refused(pill: ObsidianLatchJS.cliOffPill) }
            guard ObsidianLatchJS.supported(version) else {
                return .refused(pill: ObsidianLatchJS.versionPill)
            }
            guard let reply = cli.eval(ObsidianLatchJS.pin(id: nextID)), reply.ok == true else {
                return notSupported   // not a markdown editor leaf
            }
            let pin = LatchPin(method: .obsidianCLI, bundleID: ObsidianLatchJS.bundleID, appName: appName,
                               documentName: reply.name ?? "note", handle: reply.path ?? "")
            return .pinned(ObsidianLatchTarget(pin: pin, cli: cli, id: nextID))
        case .axSelectedText?:
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, let bundleID,
                  let target = AXSelectedTextLatchTarget(pid: pid, bundleID: bundleID, appName: appName)
            else { return notSupported }
            return .pinned(target)
        case nil:
            return notSupported
        }
    }
}
