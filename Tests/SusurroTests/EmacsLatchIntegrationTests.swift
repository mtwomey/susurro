import Foundation
import Testing
@testable import SusurroCore

/// Live check of the Emacs latch Lisp against a hidden scratch buffer in the
/// running Emacs server (never the user's buffers; never takes focus).
/// Opt-in: SUSURRO_EMACS_IT=1 swift test --filter EmacsLatchIntegration
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUSURRO_EMACS_IT"] == "1"))
struct EmacsLatchIntegrationTests {
    static let buf = " *susurro-latch-test*"

    func eval(_ lisp: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/Applications/Emacs.app/Contents/MacOS/bin/emacsclient")
        p.arguments = ["-e", lisp]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try? p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// emacsclient -e prints the Lisp string with quotes; reuse the decoder.
    func decode(_ printed: String) -> EmacsLatchLisp.Reply {
        EmacsLatchLisp.decode(reply: "-print " + EmacsServerProtocol.quote(printed + "\n") + "\n")
    }

    @Test func markerInsertReadBackTracksEditsAndDetectsKill() {
        let id = 9_901, sym = EmacsLatchLisp.markerSymbol(id)
        // Scratch setup standing in for pin(): hidden buffer, marker at end.
        _ = eval("""
        (with-current-buffer (get-buffer-create "\(Self.buf)") (erase-buffer) (insert "Hello") \
        (defvar \(sym) nil) (setq \(sym) (copy-marker (point-max) t)) t)
        """)
        #expect(decode(eval(EmacsLatchLisp.context(id: id))) == .value("Hello"))
        #expect(decode(eval(EmacsLatchLisp.insert(id: id, text: " world."))) == .value(" world."))
        // User edits before the marker; the marker must track them.
        _ = eval("(with-current-buffer \"\(Self.buf)\" (goto-char (point-min)) (insert \"Say: \") t)")
        #expect(decode(eval(EmacsLatchLisp.insert(id: id, text: " Ünïcode \"q\" & (x)"))) == .value(" Ünïcode \"q\" & (x)"))
        let whole = eval("(with-current-buffer \"\(Self.buf)\" (buffer-string))")
        #expect(whole == "\"Say: Hello world. Ünïcode \\\"q\\\" & (x)\"")
        // Buffer closed: GONE, nothing written anywhere.
        _ = eval("(kill-buffer \"\(Self.buf)\")")
        #expect(decode(eval(EmacsLatchLisp.insert(id: id, text: "lost"))) == .gone)
        #expect(decode(eval(EmacsLatchLisp.context(id: id))) == .gone)
        #expect(decode(eval(EmacsLatchLisp.release(id: id))) == .value("OK"))
        #expect(eval("(boundp '\(sym))") == "nil")
    }
}
