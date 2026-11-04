import Foundation
import Testing
@testable import SusurroCore

@Suite struct ParakeetEngineTests {
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("susurro-parakeet-\(UUID().uuidString)")
            .appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func shortBuffersArePaddedToOneSecond() {
        let padded = ParakeetEngine.padded([Float](repeating: 0.5, count: 1_000))
        #expect(padded.count == 16_000)
        #expect(padded[999] == 0.5)
        #expect(padded[1_000] == 0)
    }

    /// Trailing silence is always appended, even when the clip is already
    /// over the one-second minimum, so Parakeet emits the final ? or .
    @Test func everyBufferGetsTrailingSilence() {
        let samples = [Float](repeating: 0.1, count: 20_000)
        let padded = ParakeetEngine.padded(samples)
        #expect(padded.count == 20_000 + ParakeetEngine.trailingSilenceSamples)
        #expect(Array(padded.prefix(20_000)) == samples)
        #expect(padded.suffix(ParakeetEngine.trailingSilenceSamples).allSatisfy { $0 == 0 })
    }

    @Test func shortClipStillGetsFullTrailingSilence() {
        // 0.5 s of speech + 0.5 s of silence = 1 s, exactly the minimum, above the minimum.
        let padded = ParakeetEngine.padded([Float](repeating: 0.5, count: 8_000))
        #expect(padded.count == 8_000 + ParakeetEngine.trailingSilenceSamples)
    }

    @Test func engineKindInferredFromPath() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        #expect(TranscriptionEngines.kind(ofPath: dir.path) == .parakeet)
        #expect(TranscriptionEngines.kind(ofPath: "/nonexistent/ggml-small.en.bin") == .whisper)
    }

    /// An incomplete model directory must throw (-> "Model load failed"),
    /// never fall through to FluidAudio's silent re-download.
    @Test func incompleteDirectoryFailsWithoutDownloading() throws {
        let dir = try scratchDir()
        let parent = dir.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(throws: ParakeetEngineError.self) {
            _ = try TranscriptionEngines.load(modelPath: dir.path, engine: .parakeet)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
