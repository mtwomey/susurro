import Foundation
import Testing
@testable import SusurroCore

/// Scripted engine: returns queued transcripts in order (BEA-664 golden tests
/// run the real pipeline without a model).
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    static let sampleRate = 16_000
    let kind: EngineKind
    private let lock = NSLock()
    private var queue: [String]
    private(set) var calls: [Int] = []   // sample counts seen
    init(_ kind: EngineKind, transcripts: [String]) { self.kind = kind; queue = transcripts }
    func transcribe(samples: [Float]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        calls.append(samples.count)
        return queue.isEmpty ? "" : queue.removeFirst()
    }
}

private func freshRules() -> PostProcessor {
    PostProcessor(userRulesURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("susurro-test-\(UUID().uuidString)/rules.json"))
}

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

struct DictationPipelineTests {
    /// Golden: the `susurro-cli --post` output captured on main c9eaa1e
    /// (Fixtures/golden, raw<TAB>processed) must come back unchanged from the
    /// pipeline for the raw engine transcripts of Fixtures/punct and Fixtures/ab.
    @Test(arguments: ["post_whisper_punct", "post_whisper_ab", "post_parakeet_punct", "post_parakeet_ab"])
    func postGolden(_ name: String) throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Fixtures/golden/\(name).tsv"), encoding: .utf8)
        let rows = text.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
        #expect(rows.count >= 6)
        let kind: EngineKind = name.contains("parakeet") ? .parakeet : .whisper
        let pipeline = DictationPipeline(engine: FakeEngine(kind, transcripts: []), postProcessor: freshRules())
        for (raw, expected) in rows {
            #expect(pipeline.postProcessed(raw).replacingOccurrences(of: "\n", with: "\\n") == expected)
        }
    }

    @Test func handsFreeJoinUsesJointClip() throws {
        let engine = FakeEngine(.parakeet, transcripts: ["so I was thinking that we should probably move the deploy to Thursday."])
        let pipeline = DictationPipeline(engine: engine, postProcessor: freshRules())
        var joiner = HeldMarkJoiner()
        let a = DictationPipeline.ChunkAudio(samples: .init(repeating: 0, count: 32_000), firstSpeech: 0, lastSpeech: 30_000)
        let b = DictationPipeline.ChunkAudio(samples: .init(repeating: 0, count: 16_000), firstSpeech: 1_000, lastSpeech: 15_000)
        var t: Duration?
        let first = try pipeline.handsFreeStep(joiner.accept("So I was thinking that we should probably.", pid: 1),
                                               previous: nil, current: a, jointSeconds: &t)
        #expect(first == .fresh(text: "So I was thinking that we should probably"))
        #expect(t == nil && engine.calls.isEmpty)
        let second = try pipeline.handsFreeStep(joiner.accept("Move the deploy to Thursday.", pid: 1),
                                                previous: a, current: b, jointSeconds: &t)
        guard case .joined(_, let decision, _, let joined) = second else { Issue.record("no join"); return }
        #expect(decision == .continuation)
        #expect(joined == " move the deploy to Thursday")
        #expect(engine.calls.count == 1 && t != nil)
    }

    @Test func failedJointClipIsUnmatchedInAppPolicy() throws {
        final class Failing: TranscriptionEngine, @unchecked Sendable {
            static let sampleRate = 16_000
            let kind = EngineKind.parakeet
            struct E: Error {}
            func transcribe(samples: [Float]) throws -> String { throw E() }
        }
        let pipeline = DictationPipeline(engine: Failing(), postProcessor: freshRules())
        var joiner = HeldMarkJoiner()
        let a = DictationPipeline.ChunkAudio(samples: .init(repeating: 0, count: 16_000), firstSpeech: 0, lastSpeech: 15_000)
        _ = joiner.accept("First part.", pid: 1)
        var t: Duration?
        let step = try pipeline.handsFreeStep(joiner.accept("Second part.", pid: 1), previous: a, current: a,
                                              jointSeconds: &t, failedJointAsEmpty: true)
        guard case .joined(_, let decision, _, _) = step else { Issue.record("no join"); return }
        #expect(decision == .unmatched)
        #expect(throws: (any Error).self) {
            try pipeline.handsFreeStep(.needsJoin(held: .init(mark: ".", body: "x", pid: 1), next: "y"),
                                       previous: a, current: a, jointSeconds: &t)
        }
    }

    @Test func emptyAfterFilterStaysEmpty() async {
        let pipeline = DictationPipeline(engine: FakeEngine(.whisper, transcripts: []), postProcessor: freshRules())
        #expect(pipeline.clean("") == "")
        #expect(pipeline.postProcessed("") == "")
        #expect(await pipeline.cleanDictation("") == "")
    }

    /// Golden: `susurro-cli --handsfree` outputs replayed through the
    /// pipeline with the recorded raw engine transcripts and a fake engine.
    /// - handsfree_voice: Fixtures/voice, captured on main c9eaa1e.
    /// - handsfree_eval: the 41 stitched sessions from
    ///   scripts/handsfree_join_eval.py (28 joins), set HF_EVAL_DIR to its
    ///   out-dir to run them.
    /// The audio is not committed (Matthew's voice); missing files are skipped.
    @Test(arguments: [("handsfree_voice", "Fixtures/voice"), ("handsfree_eval", "$HF_EVAL_DIR")])
    func handsFreeReplayGolden(_ name: String, _ dir: String) throws {
        let golden = repoRoot.appendingPathComponent("Fixtures/golden")
        func lines(_ f: String) throws -> [[String: Any]] {
            try String(contentsOf: golden.appendingPathComponent(f), encoding: .utf8)
                .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        let expected = try lines("\(name).jsonl"), raws = try lines("\(name)_raw.jsonl")
        #expect(expected.count == raws.count && !expected.isEmpty)
        let base: URL
        if dir.hasPrefix("$") {
            guard let env = ProcessInfo.processInfo.environment[String(dir.dropFirst())] else { return }
            base = URL(fileURLWithPath: env)
        } else {
            base = repoRoot.appendingPathComponent(dir)
        }
        for (exp, raw) in zip(expected, raws) {
            let file = exp["file"] as! String
            #expect(raw["file"] as? String == file)
            let wav = base.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            let engine = FakeEngine(.parakeet, transcripts: raw["raw"] as! [String])
            let pipeline = DictationPipeline(engine: engine, postProcessor: freshRules())
            let r = try pipeline.replayHandsFree(try AudioFileLoader.loadSamples(url: wav))
            #expect(r.chunks == exp["chunks"] as! [String], "\(file)")
            #expect(r.decisions == exp["decisions"] as! [String], "\(file)")
            #expect(r.typed == exp["typed"] as! String, "\(file)")
            #expect(engine.calls.count == (raw["raw"] as! [String]).count, "\(file)")
        }
    }
}
