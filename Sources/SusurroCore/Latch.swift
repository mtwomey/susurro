import Foundation

// Latch v1 (BEA-691): text stays tied to the target pinned when latch began,
// while the user works elsewhere. Full support or nothing: latch engages only
// for apps on the static, bundled allowlist below; everywhere else the app
// shows "Latching isn't supported in <app>" and the session stays hands-free.
// Pure types only; the bridges that talk to apps live in the app target.

/// How text reaches a latched target.
public enum LatchMethod: String, Sendable, Equatable, Codable {
    /// Obsidian's official CLI (`obsidian eval`) driving the CM6 editor.
    case obsidianCLI
    /// The running Emacs server, inserting at a marker.
    case emacsServer
    /// Accessibility `kAXSelectedText` write on the remembered element.
    case axSelectedText
}

/// One allowlist entry. `Codable` so a remote list can be layered on later
/// (out of scope for v1).
public struct LatchCapability: Sendable, Equatable, Codable {
    public var bundleID: String
    public var method: LatchMethod
    public init(bundleID: String, method: LatchMethod) {
        self.bundleID = bundleID
        self.method = method
    }
}

/// The static, bundled v1 allowlist. TextEdit is added only once its in-app
/// undo check passes (see docs); Notes stays off.
public struct LatchAllowlist: Sendable, Equatable {
    public static let bundled = LatchAllowlist(entries: [
        LatchCapability(bundleID: "md.obsidian", method: .obsidianCLI),
        LatchCapability(bundleID: "org.gnu.Emacs", method: .emacsServer),
    ])

    public var entries: [LatchCapability]
    public init(entries: [LatchCapability]) { self.entries = entries }

    public func method(for bundleID: String?) -> LatchMethod? {
        guard let bundleID else { return nil }
        return entries.first { $0.bundleID == bundleID }?.method
    }
}

/// A pinned latch target. `handle` is bridge-specific and opaque to the
/// session (Emacs: marker variable name; Obsidian: leaf id + file path).
public struct LatchPin: Sendable, Equatable {
    public var method: LatchMethod
    public var bundleID: String
    public var appName: String
    /// Shown on the overlay: note or buffer name.
    public var documentName: String
    public var handle: String
    public init(method: LatchMethod, bundleID: String, appName: String, documentName: String, handle: String) {
        self.method = method
        self.bundleID = bundleID
        self.appName = appName
        self.documentName = documentName
        self.handle = handle
    }
}

/// What the target reports after one insert.
public struct LatchReadBack: Sendable, Equatable {
    /// Text immediately before the insertion point, read before inserting.
    public var contextBefore: String
    /// The text now sitting where the chunk was inserted.
    public var inserted: String
    public init(contextBefore: String, inserted: String) {
        self.contextBefore = contextBefore
        self.inserted = inserted
    }
}

/// Why a latched chunk could not be delivered.
public enum LatchFailure: Sendable, Equatable {
    /// The pinned buffer/note/leaf is gone.
    case targetGone
    /// The bridge did not answer (server stopped, CLI off, timeout).
    case bridgeUnavailable
    /// The read-back does not match what was sent.
    case readBackMismatch
}

/// Per-chunk delivery policy: verify by read-back; on any failure the chunk
/// goes to the clipboard, a pill explains, and latch ends (the session keeps
/// recording in hands-free). Never retries elsewhere: the wrong-app invariant
/// says text only ever goes to the pinned target.
public enum LatchDelivery {
    public enum Outcome: Sendable, Equatable {
        case delivered
        case failed(LatchFailure)
    }

    public enum Action: Sendable, Equatable {
        case copyToClipboard(String)
        case pill(String)
        case endLatch
    }

    /// `readBack` nil means the bridge could not reach the target at all;
    /// `targetAlive` false means it answered that the target is gone.
    public static func verify(sent: String, readBack: LatchReadBack?, targetAlive: Bool = true) -> Outcome {
        guard targetAlive else { return .failed(.targetGone) }
        guard let readBack else { return .failed(.bridgeUnavailable) }
        return readBack.inserted == sent ? .delivered : .failed(.readBackMismatch)
    }

    public static func actions(for outcome: Outcome, sent: String, pin: LatchPin) -> [Action] {
        guard case .failed(let failure) = outcome else { return [] }
        var actions: [Action] = []
        if !sent.isEmpty { actions.append(.copyToClipboard(sent)) }
        actions.append(.pill(pillText(failure, pin: pin)))
        actions.append(.endLatch)
        return actions
    }

    public static func pillText(_ failure: LatchFailure, pin: LatchPin) -> String {
        let what = pin.method == .emacsServer ? "the buffer" : "the note"
        switch failure {
        case .targetGone:
            return "Latch ended: \(pin.appName) closed \(what) — text copied"
        case .bridgeUnavailable:
            return "Latch ended: \(pin.appName) stopped answering — text copied"
        case .readBackMismatch:
            return "Latch ended: couldn't confirm the text in \(pin.appName) — text copied"
        }
    }

    public static func notSupportedPill(appName: String) -> String {
        "Latching isn't supported in \(appName)"
    }
}

/// A bridge's answer about a latched target.
public enum LatchBridgeReply: Sendable, Equatable {
    case value(String)
    /// The pinned buffer/note is gone.
    case gone
    /// No usable answer (server down, CLI off, timeout).
    case unavailable
}

/// One pinned latch target, as the session sees it. Implemented per bridge in
/// the app target (Emacs today, Obsidian next); fakes in tests. Calls block
/// briefly (socket/CLI round trip).
public protocol LatchTarget: AnyObject, Sendable {
    var pin: LatchPin { get }
    /// Text before the pinned position, for joins and spacing.
    func context() -> LatchBridgeReply
    /// Insert at the pinned position and advance it; replies with the text
    /// now sitting where it was inserted (the read-back).
    func insert(_ text: String) -> LatchBridgeReply
    /// Let go of the pin (marker, position tracker).
    func release()
}

extension LatchDelivery {
    /// Insert `text` into the pinned target and verify the read-back.
    public static func deliver(_ text: String, to target: any LatchTarget,
                               contextBefore: String = "") -> Outcome {
        switch target.insert(text) {
        case .gone: return .failed(.targetGone)
        case .unavailable: return .failed(.bridgeUnavailable)
        case .value(let back):
            return verify(sent: text, readBack: LatchReadBack(contextBefore: contextBefore, inserted: back))
        }
    }

    /// Context failure before inserting: the outcome to report, nil if fine.
    public static func contextFailure(_ reply: LatchBridgeReply) -> Outcome? {
        switch reply {
        case .value: return nil
        case .gone: return .failed(.targetGone)
        case .unavailable: return .failed(.bridgeUnavailable)
        }
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
