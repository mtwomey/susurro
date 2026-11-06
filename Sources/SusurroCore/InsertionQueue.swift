import Foundation

// BEA-665 (architecture review R3, finding F3). One serial FIFO for every
// dictation that types text — push-to-talk releases and hands-free chunks
// alike — plus the seams (Inserter, FrontmostAppProvider) that let the insert
// side be tested without synthesising keystrokes.

/// Types text into the frontmost app. The app's implementation wraps
/// TextInjector (CGEvent keystrokes); tests use a recording fake.
@MainActor
public protocol Inserter: AnyObject {
    /// Type `text`. False if any keystroke event failed to post.
    func type(_ text: String) -> Bool
    /// Press Delete `count` times.
    func deleteBackward(_ count: Int)
}

/// Which app would receive keystrokes right now, and whether secure input
/// (a password field) would silently swallow them.
@MainActor
public protocol FrontmostAppProvider: AnyObject {
    var frontmostPID: pid_t? { get }
    var secureInputActive: Bool { get }
}

/// The general pasteboard; a fake in tests.
@MainActor
public protocol Clipboard: AnyObject {
    /// Replace the clipboard contents with `text`.
    func set(_ text: String)
}

/// Carries out an insert decided by InsertPlan: the keystrokes, the
/// clipboard / secure-input / app-switch policy and the DictationMemory
/// bookkeeping (BEA-665, R3). Owns the memory, so every writer goes through
/// the one queue that calls it.
@MainActor
public final class InsertExecutor {
    public let inserter: Inserter
    public let frontmost: FrontmostAppProvider
    public let clipboard: Clipboard
    /// What Susurro itself typed last, per app (fallback insert context).
    public var memory = DictationMemory()

    public init(inserter: Inserter, frontmost: FrontmostAppProvider, clipboard: Clipboard) {
        self.inserter = inserter
        self.frontmost = frontmost
        self.clipboard = clipboard
    }

    public static let appSwitchToast = "You switched apps — the last words were copied to the clipboard"
    public static let secureInputToast = "Typing blocked by a secure field — transcript copied to clipboard"

    /// A hands-free chunk finished after the user switched apps: never type it
    /// where they didn't dictate. Copies `text` and forgets the remembered
    /// tail. Returns the toast to show.
    public func copyAfterAppSwitch(_ text: String) -> String {
        clipboard.set(text)
        memory.clear()
        return Self.appSwitchToast
    }

    public struct Result: Equatable, Sendable {
        /// Every keystroke posted.
        public var typed: Bool
        /// The insertion was remembered (typed, not secure, app known).
        public var recorded: Bool
        /// Time spent on the keystrokes (delete + type).
        public var insertDuration: Duration
        public var toast: String?
    }

    /// Retract `deleteBackward` characters (a shown hands-free mark), type
    /// `text`, then update memory and the clipboard:
    /// - typed, not secure, app known: remember it (`position`, `continuesTail`
    ///   as DictationMemory.recordTyped);
    /// - otherwise (secure input, a failed keystroke, no frontmost app): clear
    ///   the memory so a stale tail can't leak into the next field;
    /// - copy to the clipboard when `copyToClipboard` is on or secure input
    ///   blocked typing (toast only in the latter case).
    public func insert(_ text: String, deleteBackward deleteCount: Int, frontmostPID: pid_t?,
                       secureInput: Bool, copyToClipboard: Bool,
                       position: ValuePosition?, continuesTail: Bool) -> Result {
        let start = ContinuousClock.now
        if deleteCount > 0, let frontmostPID {
            inserter.deleteBackward(deleteCount)
            memory.recordDeletedBackward(deleteCount, inPID: frontmostPID)
        }
        let typed = inserter.type(text)
        var result = Result(typed: typed, recorded: false, insertDuration: ContinuousClock.now - start)
        if !secureInput, typed, let frontmostPID {
            memory.recordTyped(text, intoPID: frontmostPID, position: position, continuesTail: continuesTail)
            result.recorded = true
        } else {
            memory.clear()
        }
        if copyToClipboard || secureInput {
            clipboard.set(text)
            if secureInput && !copyToClipboard { result.toast = Self.secureInputToast }
        }
        return result
    }

    /// End of a hands-free session: type the held mark (HeldMarkTail rules)
    /// and remember it.
    public func typeHeldMark(_ mark: Character?, sessionPID: pid_t?) {
        if let typed = HeldMarkTail.type(mark: mark, sessionPID: sessionPID,
                                         frontmost: frontmost, inserter: inserter),
           let sessionPID {
            memory.recordTyped(typed, intoPID: sessionPID)
        }
    }
}

/// A serial, cancel-aware FIFO of insertion jobs on the main actor.
///
/// Each job runs only after the previous one has finished (transcription,
/// optional LLM clean-up, AX read and typing included), so two quick
/// push-to-talk dictations — or a push-to-talk dictation right after a
/// hands-free stop — can never type out of order or interleave their
/// DictationMemory updates. A job carries a gate: when its turn comes and
/// the gate says the work is stale (hands-free session cancelled), it is
/// skipped without running.
@MainActor
public final class InsertionQueue {
    private var tail: Task<Void, Never>?
    /// Jobs enqueued and not yet finished (or skipped).
    public private(set) var pending = 0

    public init() {}

    /// Append `work` to the queue. `isCurrent` is checked when the job's turn
    /// comes; false = skip. Returns the job's task (finishes when it ran or
    /// was skipped).
    @discardableResult
    public func enqueue(isCurrent: @escaping @MainActor () -> Bool = { true },
                        _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        pending += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            defer { self?.pending -= 1 }
            guard isCurrent() else { return }
            await work()
        }
        tail = task
        return task
    }

    /// Wait until everything enqueued so far has finished.
    public func drain() async {
        await tail?.value
    }
}

/// End of a hands-free session (BEA-657): after the last chunk, type its held
/// end mark — only into the app the session dictated into and never through
/// secure input. Returns the text typed (for DictationMemory), or nil.
public enum HeldMarkTail {
    @MainActor
    public static func type(mark: Character?, sessionPID: pid_t?,
                            frontmost: FrontmostAppProvider, inserter: Inserter) -> String? {
        guard let mark, let sessionPID, frontmost.frontmostPID == sessionPID,
              !frontmost.secureInputActive else { return nil }
        let text = String(mark)
        return inserter.type(text) ? text : nil
    }
}
