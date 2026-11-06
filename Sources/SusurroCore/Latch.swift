import Foundation

// Latch v1 (BEA-691): text stays tied to the target pinned when latch began,
// while the user works elsewhere. Full support or nothing: latch engages only
// for apps on the static, bundled allowlist below; everywhere else the app
// shows "Latching isn't supported in <app>" and the session stays hands-free.
// Pure types only; the bridges that talk to apps live in the app target.

/// A bridge's identity (docs/BRIDGES.md). A string-backed struct, not a
/// closed enum: adding a bridge needs no central edit, and a future remote
/// allowlist can name ids this build doesn't know without failing to decode.
/// Raw values match the former `LatchMethod` cases.
public struct BridgeID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }

    /// Obsidian's official CLI (`obsidian eval`) driving the CM6 editor.
    public static let obsidianCLI = BridgeID(rawValue: "obsidianCLI")
    /// The running Emacs server, inserting at a marker.
    public static let emacsServer = BridgeID(rawValue: "emacsServer")
    /// Accessibility `kAXSelectedText` write on the remembered element.
    public static let axSelectedText = BridgeID(rawValue: "axSelectedText")
}

/// Transitional name (BEA-691 bridges step 3); removed with the registry.
public typealias LatchMethod = BridgeID

/// Why a bridge call failed, distinctly (docs/BRIDGES.md §3).
public enum BridgeError: Error, Sendable, Equatable {
    /// Server down, socket missing, app not answering.
    case notRunning
    /// The app's bridge is switched off (e.g. Obsidian CLI toggle).
    case notEnabled
    case unsupportedVersion(found: [Int], minimum: [Int])
    /// No latchable target in front (minibuffer, non-markdown leaf, ...).
    case noTarget
    case targetGone
    case timeout
    case malformedReply
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
        LatchCapability(bundleID: ObsidianLatchJS.bundleID, method: .obsidianCLI),
        LatchCapability(bundleID: EmacsBridgeInfo.bundleID, method: .emacsServer),
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
    /// What the target is called in pills: "buffer", "note", "document".
    public var documentNoun: String
    public init(method: LatchMethod, bundleID: String, appName: String, documentName: String, handle: String,
                documentNoun: String = "document") {
        self.documentNoun = documentNoun
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
        let what = "the " + pin.documentNoun
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
