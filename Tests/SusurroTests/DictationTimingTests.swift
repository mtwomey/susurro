import Foundation
import Testing
@testable import SusurroCore

/// BEA-663 (review R1): F2 cancel race, F5 AX cap, F8 timings log fields.
@MainActor
struct DictationTimingTests {
    // MARK: F2 — Esc while a chunk is mid-transcription

    @Test func cancelDuringTranscriptionDropsTheChunk() async {
        var gate = SessionGate()
        var typed: [String] = []
        let token = gate.token
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let chunk = Task { @MainActor in
            await GatedChunk.run(token: token, gate: { gate },
                                 transcribe: {
                                     started.continuation.yield()
                                     for await _ in release.stream { break } // fake slow engine
                                     return "words after escape"
                                 },
                                 insert: { typed.append($0) })
        }
        for await _ in started.stream { break }
        gate.cancel()                      // Esc: "Hands-free discarded"
        release.continuation.yield()       // engine finishes afterwards
        let inserted = await chunk.value
        #expect(!inserted)
        #expect(typed.isEmpty)
    }

    @Test func uncancelledChunkIsInserted() async {
        let gate = SessionGate()
        var typed: [String] = []
        let inserted = await GatedChunk.run(token: gate.token, gate: { gate },
                                            transcribe: { "hello" }, insert: { typed.append($0) })
        #expect(inserted)
        #expect(typed == ["hello"])
    }

    @Test func gateTokens() {
        var gate = SessionGate()
        let old = gate.token
        #expect(gate.isCurrent(old))
        #expect(gate.isCurrent(nil))
        gate.cancel()
        #expect(!gate.isCurrent(old))
        #expect(gate.isCurrent(gate.token))
    }

    // MARK: F5 — the cap returns on time even if the reader hangs

    @Test func capReturnsNilAtTheCapWithASlowReader() async {
        // nil proves the cap won: the reader can only ever answer "late".
        // No wall-clock bound on the await itself: when other tests block
        // Swift's cooperative pool, resuming this task is delayed by the
        // test scheduler, not by CappedRead (BEA-698; reproducible on main
        // with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1). The cap itself
        // fires on a GCD timer, independent of that pool.
        let result = await CappedRead.run(cap: .milliseconds(50)) { () -> String in
            Thread.sleep(forTimeInterval: 1.5) // AX call stuck well past the cap
            return "late"
        }
        #expect(result == nil)
    }

    @Test func capReturnsAFastResult() async {
        let result = await CappedRead.run(cap: .milliseconds(500)) { 42 }
        #expect(result == 42)
    }

    // MARK: F8 — timings in the log line, numbers only

    @Test func timingsLogFields() {
        let t = StageTimings(axRead: .milliseconds(12), transcribe: .milliseconds(340),
                             joinTranscribe: nil, insert: .microseconds(4400))
        #expect(t.logFields == "ms_ax=12 ms_transcribe=340 ms_join=- ms_insert=4")
        #expect(StageTimings().logFields == "ms_ax=- ms_transcribe=- ms_join=- ms_insert=-")
    }
}
