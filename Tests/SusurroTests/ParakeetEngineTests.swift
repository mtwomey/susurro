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
        let padded = ParakeetEngine.padded([Float](repeating: 0.5, count: 4_800))
        #expect(padded.count == 16_000)
        #expect(padded[4_799] == 0.5)
        #expect(padded[4_800] == 0)
    }

    @Test func longBuffersAreUntouched() {
        let samples = [Float](repeating: 0.1, count: 20_000)
        #expect(ParakeetEngine.padded(samples) == samples)
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
