import Foundation

/// One latch, from pin to release (docs/BRIDGES.md §3). Every bridge call
/// runs on this session's own serial dispatch queue (the actor's executor):
/// off the main thread, off Swift's cooperative pool (bridge calls block on
/// sockets and processes), and in strict order, so `release()` can never
/// overlap an in-flight insert. Per-call time limits are the transports'
/// deadlines (Emacs 0.5 / 1 s, Obsidian CLI 3 s).
///
/// After the first failure the session is ended: later calls fail fast
/// without touching the app, only the first failure asks for a pill, and
/// every undelivered piece of text is *appended* to the clipboard text so
/// nothing already copied is lost (BEA-691 review defect 2).
public actor LatchSession {
    public struct Report: Sendable, Equatable {
        public var outcome: LatchDelivery.Outcome
        /// True only for the failure that ended the latch: show its pill and
        /// fall back to hands-free once.
        public var endedNow: Bool
        /// Everything undelivered so far, in order; nil when delivered.
        public var clipboardText: String?
    }

    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public nonisolated let pin: LatchPin
    private let target: any LatchTarget
    public private(set) var endReason: LatchFailure?
    private var released = false
    private var undelivered = ""

    public init(target: any LatchTarget) {
        self.target = target
        self.pin = target.pin
        self.queue = DispatchSerialQueue(label: "com.mtwomey.susurro.latch")
    }

    /// Text before the pin, for joins and spacing.
    public func context() -> LatchBridgeReply {
        guard endReason == nil, !released else { return .gone }
        return target.context()
    }

    /// Insert and verify by read-back.
    public func deliver(_ text: String, contextBefore: String = "") -> Report {
        if let endReason { return fail(text, endReason, endedNow: false) }
        if released { return fail(text, .targetGone, endedNow: false) }
        let outcome = LatchDelivery.deliver(text, to: target, contextBefore: contextBefore)
        guard case .failed(let why) = outcome else { return Report(outcome: outcome, endedNow: false, clipboardText: nil) }
        endReason = why
        return fail(text, why, endedNow: true)
    }

    /// A chunk that never reached `deliver` (e.g. the context read failed).
    public func fail(_ text: String, because failure: LatchFailure) -> Report {
        let first = endReason == nil
        if first { endReason = failure }
        return fail(text, endReason ?? failure, endedNow: first)
    }

    private func fail(_ text: String, _ why: LatchFailure, endedNow: Bool) -> Report {
        undelivered += text
        return Report(outcome: .failed(why), endedNow: endedNow,
                      clipboardText: undelivered.isEmpty ? nil : undelivered)
    }

    /// Let go of the pin once; later calls are no-ops.
    public func release() {
        guard !released else { return }
        released = true
        target.release()
    }

    public var isReleased: Bool { released }
}
