import Foundation

/// Emacs through its server socket (the protocol emacsclient speaks): ~2-35 ms
/// per request, no process spawned, nothing unless the server is running
/// (`M-x server-start`). Emacs 30's NS port publishes a stale buffer copy to
/// Accessibility (docs/TEXT_HANDLING_FINDINGS.md §6.1), hence the context
/// read too. The minibuffer is never read or pinned: Emacs reads passwords
/// there.
public struct EmacsBridge: ContextReadingBridge, LatchingBridge {
    public let id = BridgeID.emacsServer
    public let name = "emacs"
    public let bundleIDs: Set<String> = [EmacsBridgeInfo.bundleID]
    public let documentNoun = "buffer"
    public var readTimeout: TimeInterval = 0.15
    public var maxChars = 200

    public init() {}

    public func textBeforeCursor() -> String? {
        EmacsServerProtocol.eval(EmacsReadLisp.textBeforeCursor(maxChars: maxChars), timeout: readTimeout)
            .flatMap(EmacsServerProtocol.parse(reply:))
    }

    public func pin(_ request: LatchPinRequest) throws(BridgeError) -> any LatchTarget {
        guard EmacsServerProtocol.socketPath() != nil else { throw .notRunning }
        switch EmacsLatchLisp.decode(reply: EmacsServerProtocol.eval(EmacsLatchLisp.pin(id: request.token), timeout: 0.5)) {
        case .value(let bufferName):
            let pin = LatchPin(method: id, bundleID: request.bundleID, appName: request.appName,
                               documentName: bufferName, handle: String(request.token), documentNoun: documentNoun)
            return EmacsLatchTarget(pin: pin, token: request.token)
        case .skip: throw .noTarget
        case .gone: throw .targetGone
        case .none: throw .notRunning
        }
    }
}

/// A latched Emacs buffer: a marker with insertion type t, so it advances
/// past each insert and follows the user's edits elsewhere in the buffer.
public final class EmacsLatchTarget: LatchTarget {
    public let pin: LatchPin
    private let token: Int

    init(pin: LatchPin, token: Int) {
        self.pin = pin
        self.token = token
    }

    private func call(_ lisp: String, timeout: TimeInterval) -> LatchBridgeReply {
        switch EmacsLatchLisp.decode(reply: EmacsServerProtocol.eval(lisp, timeout: timeout)) {
        case .value(let s): return .value(s)
        case .gone: return .gone
        case .skip, .none: return .unavailable
        }
    }

    public func context() -> LatchBridgeReply { call(EmacsLatchLisp.context(id: token), timeout: 0.5) }
    public func insert(_ text: String) -> LatchBridgeReply { call(EmacsLatchLisp.insert(id: token, text: text), timeout: 1.0) }
    public func release() { _ = EmacsServerProtocol.eval(EmacsLatchLisp.release(id: token), timeout: 0.5) }
}
