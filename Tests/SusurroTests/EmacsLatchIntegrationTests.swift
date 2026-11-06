import Foundation
import Testing
@testable import SusurroCore

/// Live check of the Emacs latch Lisp against a hidden scratch buffer in the
/// running Emacs server (never the user's buffers; never takes focus).
/// Opt-in: SUSURRO_EMACS_IT=1 swift test --filter EmacsLatchIntegration
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUSURRO_EMACS_IT"] == "1"))
struct EmacsLatchIntegrationTests {
    static let buf = " *susurro-latch-test*"

    /// Shipping transport (UnixSocketClient), not emacsclient.
    func run(_ lisp: String) -> EmacsLatchLisp.Reply {
        EmacsLatchLisp.decode(reply: EmacsServerProtocol.eval(lisp, timeout: 2))
    }

    /// Setup/inspection helpers: raw printed value via the same transport.
    func eval(_ lisp: String) -> String {
        EmacsServerProtocol.eval(lisp, timeout: 2).flatMap(EmacsServerProtocol.printedString(reply:)) ?? ""
    }

    @Test func markerInsertReadBackTracksEditsAndDetectsKill() {
        let id = LatchToken.make(nonce: 222, counter: 2), sym = EmacsLatchLisp.markerSymbol(id)
        // Scratch setup standing in for pin(): hidden buffer, marker at end.
        _ = eval("""
        (with-current-buffer (get-buffer-create "\(Self.buf)") (erase-buffer) (insert "Hello") \
        (defvar \(sym) nil) (setq \(sym) (copy-marker (point-max) t)) t)
        """)
        #expect(run((EmacsLatchLisp.context(id: id))) == .value("Hello"))
        #expect(run((EmacsLatchLisp.insert(id: id, text: " world."))) == .value(" world."))
        // User edits before the marker; the marker must track them.
        _ = eval("(with-current-buffer \"\(Self.buf)\" (goto-char (point-min)) (insert \"Say: \") t)")
        #expect(run((EmacsLatchLisp.insert(id: id, text: " Ünïcode \"q\" & (x)"))) == .value(" Ünïcode \"q\" & (x)"))
        let whole = eval("(with-current-buffer \"\(Self.buf)\" (buffer-string))")
        #expect(whole == "Say: Hello world. Ünïcode \\\"q\\\" & (x)")
        // Buffer closed: GONE, nothing written anywhere.
        _ = eval("(kill-buffer \"\(Self.buf)\")")
        #expect(run((EmacsLatchLisp.insert(id: id, text: "lost"))) == .gone)
        #expect(run((EmacsLatchLisp.context(id: id))) == .gone)
        #expect(run((EmacsLatchLisp.release(id: id))) == .value("OK"))
        #expect(eval("(if (boundp '\(sym)) \"t\" \"nil\")") == "nil")
    }

    @Test func sweepReleasesOtherLaunchesOnly() {
        let stale = EmacsLatchLisp.markerSymbol(LatchToken.make(nonce: 111, counter: 1))
        let mine = EmacsLatchLisp.markerSymbol(LatchToken.make(nonce: 222, counter: 1))
        _ = eval("""
        (with-current-buffer (get-buffer-create "\(Self.buf)") (insert "x") \
        (defvar \(stale) nil) (setq \(stale) (copy-marker (point-max) t)) \
        (defvar \(mine) nil) (setq \(mine) (copy-marker (point-max) t)) t)
        """)
        _ = eval(EmacsLatchLisp.sweep(currentNonce: 222))
        #expect(eval("(if (intern-soft \"\(stale)\") \"t\" \"nil\")") == "nil")
        #expect(eval("(if (and (boundp '\(mine)) (markerp \(mine))) \"t\" \"nil\")") == "t")
        _ = eval(EmacsLatchLisp.release(id: LatchToken.make(nonce: 222, counter: 1)))
        _ = eval("(kill-buffer \"\(Self.buf)\")")
    }
}
