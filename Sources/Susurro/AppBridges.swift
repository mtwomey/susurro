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
    let bundleIDs: Set<String> = ["org.gnu.Emacs"]
    var timeout: TimeInterval = 0.15
    var maxChars = 200

    private var expression: String {
        """
        (let* ((w (selected-window)) (b (window-buffer w))) \
        (if (minibufferp b) "SKIP" \
        (with-current-buffer b (let ((p (window-point w))) \
        (base64-encode-string (encode-coding-string \
        (buffer-substring-no-properties (max (point-min) (- p \(maxChars))) p) 'utf-8) t)))))
        """
    }

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
        return LatchPin(method: .emacsServer, bundleID: "org.gnu.Emacs", appName: appName,
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

@MainActor
enum LatchTargets {
    private static var nextID = Int(Date().timeIntervalSince1970) % 100_000
    /// Pin the frontmost app's target if it is on the bundled allowlist and
    /// its bridge can pin right now; nil = refuse (pill, stay hands-free).
    static func pin(bundleID: String?, appName: String) -> (any LatchTarget)? {
        switch LatchAllowlist.bundled.method(for: bundleID) {
        case .emacsServer?:
            nextID += 1
            let bridge = EmacsServerBridge()
            guard let pin = bridge.latchPin(id: nextID, appName: appName) else { return nil }
            return EmacsLatchTarget(pin: pin, bridge: bridge)
        case .obsidianCLI?, .axSelectedText?, nil:
            return nil   // Obsidian bridge lands next (BEA-691 M5)
        }
    }
}
