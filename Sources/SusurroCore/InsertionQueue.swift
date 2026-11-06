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
