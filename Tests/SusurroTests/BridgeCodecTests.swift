import Testing
@testable import SusurroCore

@Suite struct BridgeCodecConstantsTests {
    /// The exact read-path Lisp shipped before the move (BEA-691 step 1).
    @Test func emacsReadLispUnchanged() {
        let expected = """
        (let* ((w (selected-window)) (b (window-buffer w))) \
        (if (minibufferp b) "SKIP" \
        (with-current-buffer b (let ((p (window-point w))) \
        (base64-encode-string (encode-coding-string \
        (buffer-substring-no-properties (max (point-min) (- p 200)) p) 'utf-8) t)))))
        """
        #expect(EmacsReadLisp.textBeforeCursor(maxChars: 200) == expected)
    }

    @Test func constantsDefinedOnce() {
        #expect(EmacsBridgeInfo.bundleID == "org.gnu.Emacs")
        #expect(ObsidianLatchJS.bundleID == "md.obsidian")
        #expect(ObsidianLatchJS.versionPill == "Latching needs Obsidian 1.14.5 or later")
        #expect(LatchAllowlist.bundled.method(for: "org.gnu.Emacs") == .emacsServer)
        #expect(LatchAllowlist.bundled.method(for: "md.obsidian") == .obsidianCLI)
    }
}
