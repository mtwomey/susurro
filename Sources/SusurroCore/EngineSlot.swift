import Foundation

/// Model-swap memory policy (review F7, R8).
///
/// The slot holds the app's current engine. Each dictation takes an
/// `EngineLease` when it starts and keeps it until its job has finished, so a
/// dictation started before a model switch always completes on the engine it
/// started with (never dropped, never re-routed to the new model).
///
/// On a switch (`retire()` when the new load starts, then `install(_:)` when it
/// finishes) the slot drops its own reference to the old engine at once. The
/// old engine is then kept alive only by leases still in flight and is freed
/// as soon as the last one is released — that is, when in-flight work drains.
/// With nothing in flight it is freed immediately, so old and new are never
/// both resident unless a dictation genuinely still needs the old one. Both
/// cases are logged on `Log.engine`.
///
/// Thread-safe: leases may be released from any task.
public final class EngineSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: (any TranscriptionEngine)?
    private var generation = 0
    /// Outstanding leases per engine generation.
    private var leases: [Int: Int] = [:]
    /// Kind of each retired generation that still has leases out.
    private var retired: [Int: EngineKind] = [:]
    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { Log.engine.event($0) }) {
        self.log = log
    }

    /// The engine new dictations would use; nil while a load is in progress.
    public var current: (any TranscriptionEngine)? {
        lock.lock(); defer { lock.unlock() }
        return engine
    }

    /// Number of retired engines still held by in-flight dictations.
    public var retiredInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return retired.count
    }

    /// Take a lease on the current engine for one dictation; nil when there
    /// is no engine. Keep it until the dictation's job has finished.
    public func lease() -> EngineLease? {
        lock.lock(); defer { lock.unlock() }
        guard let engine else { return nil }
        leases[generation, default: 0] += 1
        return EngineLease(engine: engine, generation: generation, slot: self)
    }

    /// A new load is starting: drop the slot's reference to the current
    /// engine. In-flight leases keep it alive until they finish.
    public func retire() {
        lock.lock()
        guard let old = engine else { lock.unlock(); return }
        let kind = old.kind
        let inFlight = leases[generation] ?? 0
        if inFlight > 0 { retired[generation] = kind }
        engine = nil
        generation += 1
        lock.unlock()
        if inFlight > 0 {
            log("model swap: old \(kind.rawValue) engine kept for \(inFlight) in-flight dictation(s); released when they finish")
        } else {
            log("model swap: old \(kind.rawValue) engine released (nothing in flight)")
        }
    }

    /// The new load finished: new dictations use `engine` from now on.
    public func install(_ newEngine: any TranscriptionEngine) {
        retire()
        lock.lock()
        engine = newEngine
        lock.unlock()
        log("model swap: \(newEngine.kind.rawValue) engine installed")
    }

    fileprivate func release(generation gen: Int) {
        lock.lock()
        let left = (leases[gen] ?? 1) - 1
        leases[gen] = left > 0 ? left : nil
        let drainedKind = left <= 0 ? retired.removeValue(forKey: gen) : nil
        lock.unlock()
        if let drainedKind {
            log("model swap: old \(drainedKind.rawValue) engine released after in-flight work drained")
        }
    }
}

/// One dictation's hold on the engine it started with (see `EngineSlot`).
/// Releasing the last lease on a retired engine frees it.
public final class EngineLease: @unchecked Sendable {
    public let engine: any TranscriptionEngine
    private let generation: Int
    private weak var slot: EngineSlot?

    fileprivate init(engine: any TranscriptionEngine, generation: Int, slot: EngineSlot) {
        self.engine = engine
        self.generation = generation
        self.slot = slot
    }

    deinit { slot?.release(generation: generation) }
}
