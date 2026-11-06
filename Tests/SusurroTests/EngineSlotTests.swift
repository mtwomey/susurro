import Foundation
import Testing
@testable import SusurroCore

/// Fake engine that reports its own deinit, and can block mid-transcribe so a
/// model switch lands while a dictation is in flight.
final class TrackedEngine: TranscriptionEngine, @unchecked Sendable {
    static let sampleRate = 16_000
    let kind: EngineKind
    let text: String
    private let onDeinit: @Sendable () -> Void
    private let gate: DispatchSemaphore?
    init(_ kind: EngineKind, text: String, gate: DispatchSemaphore? = nil,
         onDeinit: @escaping @Sendable () -> Void) {
        self.kind = kind; self.text = text; self.gate = gate; self.onDeinit = onDeinit
    }
    func transcribe(samples: [Float]) throws -> String {
        gate?.wait()
        return text
    }
    deinit { onDeinit() }
}

final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<String> = []
    private var lines: [String] = []
    func mark(_ s: String) { lock.lock(); set.insert(s); lock.unlock() }
    func has(_ s: String) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(s) }
    func log(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var logLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Suite struct EngineSlotTests {
    @Test func oldEngineReleasedImmediatelyWhenNothingInFlight() {
        let flags = Flags()
        let slot = EngineSlot(log: { flags.log($0) })
        slot.install(TrackedEngine(.whisper, text: "old", onDeinit: { flags.mark("old") }))
        slot.retire()
        #expect(flags.has("old"))
        #expect(slot.current == nil)
        #expect(slot.retiredInFlight == 0)
        #expect(flags.logLines.contains { $0.contains("released (nothing in flight)") })
    }

    @Test func oldEngineReleasedAfterInFlightJobDrains() async throws {
        let flags = Flags()
        let slot = EngineSlot(log: { flags.log($0) })
        let gate = DispatchSemaphore(value: 0)
        slot.install(TrackedEngine(.whisper, text: "before swap", gate: gate,
                                   onDeinit: { flags.mark("old") }))
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        // A dictation started before the swap.
        var lease = slot.lease()
        #expect(lease != nil)
        let job = Task.detached { [lease] () -> String in
            startedCont.yield()
            return try await offPool { try withExtendedLifetime(lease) { try lease!.engine.transcribe(samples: [0]) } }
        }
        for await _ in started { break }
        // Swap: load starts (retire), new engine installed.
        slot.retire()
        slot.install(TrackedEngine(.parakeet, text: "after swap", onDeinit: { flags.mark("new") }))
        #expect(!flags.has("old"), "old engine must stay alive while its job is in flight")
        #expect(slot.retiredInFlight == 1)
        #expect(slot.current?.kind == .parakeet)
        // Let the in-flight job finish: it completes on the OLD engine.
        gate.signal()
        #expect(try await job.value == "before swap")
        lease = nil
        #expect(await eventually { flags.has("old") }, "old engine freed once in-flight work drained")
        #expect(!flags.has("new"))
        #expect(slot.retiredInFlight == 0)
        #expect(flags.logLines.contains { $0.contains("kept for 1 in-flight") })
        #expect(flags.logLines.contains { $0.contains("released after in-flight work drained") })
    }

    @MainActor
    @Test func noDictationLostOrMisroutedAcrossSwap() async throws {
        let flags = Flags()
        let slot = EngineSlot(log: { flags.log($0) })
        let queue = InsertionQueue()
        let inserted = Box()
        let gate = DispatchSemaphore(value: 0)
        slot.install(TrackedEngine(.whisper, text: "one", gate: gate, onDeinit: { flags.mark("old") }))

        // Mirrors DictationController: lease at key release, transcribe off-main,
        // then enqueue the insert; the lease lives until the job ends.
        func dictate() -> Task<Void, Never>? {
            guard let lease = slot.lease() else { return nil }
            return Task.detached {
                defer { withExtendedLifetime(lease) {} }
                let text = (try? await offPool { try lease.engine.transcribe(samples: [0]) }) ?? "<failed>"
                await queue.enqueue { inserted.items.append(text) }.value
            }
        }
        let first = try #require(dictate())        // started on the old engine
        slot.retire()                              // user picks another model
        #expect(dictate() == nil)                  // while loading: ignored, as today
        slot.install(TrackedEngine(.parakeet, text: "two", onDeinit: { flags.mark("new") }))
        let second = try #require(dictate())       // started on the new engine
        await second.value
        #expect(!flags.has("old"))
        gate.signal()
        await first.value
        await queue.drain()
        #expect(inserted.items.sorted() == ["one", "two"], "both dictations inserted, each from its own engine")
        #expect(await eventually { flags.has("old") })
        #expect(!flags.has("new"))
    }
}

@MainActor final class Box { var items: [String] = [] }

/// Task closures are freed shortly after the task completes; poll briefly.
func eventually(_ cond: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return cond()
}

/// Run blocking fake-engine work on a GCD thread, never a cooperative-pool
/// thread: a gated fake blocking the pool would starve wall-clock tests
/// (DictationTimingTests' CappedRead) on the 3-core CI runner.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async { cont.resume(with: Result { try work() }) }
    }
}
