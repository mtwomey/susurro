import Foundation

// BEA-663 (architecture review R1: F2, F5, F8). Small, app-independent pieces
// of the dictation path, kept here so they can be tested without the app.

// MARK: - F2: hands-free session gate

/// Hands-free session token. Cancelling (Esc) moves the gate to a new
/// generation; work captured under an older token must neither be typed nor
/// touch the joiner. Checked when a chunk starts *and* again at insert time,
/// because a chunk can be mid-transcription when the user cancels.
public struct SessionGate: Sendable, Equatable {
    public private(set) var generation = 0
    public init() {}
    /// Token for work started now.
    public var token: Int { generation }
    /// Invalidate every token handed out so far.
    public mutating func cancel() { generation += 1 }
    /// nil = not hands-free (push-to-talk), always current.
    public func isCurrent(_ token: Int?) -> Bool { token == nil || token == generation }
}

/// One hands-free chunk: transcribe, then insert — skipped if the session was
/// cancelled at either point. Mirrors the app's chunk step so the cancel race
/// can be tested with a fake (slow) engine.
public enum GatedChunk {
    /// Returns true if `insert` ran.
    @MainActor
    public static func run(token: Int, gate: @MainActor () -> SessionGate,
                           transcribe: @Sendable () async -> String,
                           insert: @MainActor (String) -> Void) async -> Bool {
        guard gate().isCurrent(token) else { return false }
        let text = await transcribe()
        guard gate().isCurrent(token) else { return false }
        insert(text)
        return true
    }
}

// MARK: - F5: a cap that is really a cap

/// Runs blocking `work` on a dispatch queue and returns its result, or nil as
/// soon as `cap` elapses — whichever comes first. Unlike a task group, it does
/// not wait for the (non-cancellable) work to finish; a late result is dropped.
public enum CappedRead {
    public static func run<T: Sendable>(cap: Duration,
                                        queue: DispatchQueue = .global(qos: .userInitiated),
                                        _ work: @escaping @Sendable () -> T) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.set(continuation)
            queue.async { once.resume(work()) }
            let c = cap.components
            let nanos = max(0, c.seconds) * 1_000_000_000 + max(0, c.attoseconds) / 1_000_000_000
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: nanos))) { once.resume(nil) }
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    func set(_ c: CheckedContinuation<T, Never>) { lock.lock(); continuation = c; lock.unlock() }
    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - F8: per-stage timings

/// Per-stage durations for one dictation, rendered into the text-handling
/// log line. Numbers only — never field or transcript text.
public struct StageTimings: Sendable, Equatable {
    public var axRead: Duration?
    public var transcribe: Duration?
    public var joinTranscribe: Duration?
    public var insert: Duration?
    public init(axRead: Duration? = nil, transcribe: Duration? = nil,
                joinTranscribe: Duration? = nil, insert: Duration? = nil) {
        self.axRead = axRead
        self.transcribe = transcribe
        self.joinTranscribe = joinTranscribe
        self.insert = insert
    }

    /// e.g. `ms_ax=12 ms_transcribe=340 ms_join=- ms_insert=4` (`-` = stage not run).
    public var logFields: String {
        func ms(_ d: Duration?) -> String {
            guard let d else { return "-" }
            let c = d.components
            return String(Int((Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15).rounded()))
        }
        return "ms_ax=\(ms(axRead)) ms_transcribe=\(ms(transcribe)) ms_join=\(ms(joinTranscribe)) ms_insert=\(ms(insert))"
    }
}
