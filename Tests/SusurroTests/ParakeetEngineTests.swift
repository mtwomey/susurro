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

    // MARK: - two-pass terminal punctuation (BEA-643)

    @Test func onlyTheFinalMarkComesFromThePaddedPass() {
        // Padded pass reformats the body ("3.30", hallucinated "Yeah."); only its mark is used.
        #expect(ParakeetEngine.withTerminalMark("The meeting is at 3:30 p.m", from: "The meeting is at 3.30 p.m. Yeah.")
                == "The meeting is at 3:30 p.m.")
        #expect(ParakeetEngine.withTerminalMark("Hey are you coming to lunch today", from: "Hey are you coming to lunch today?")
                == "Hey are you coming to lunch today?")
        #expect(ParakeetEngine.withTerminalMark("Watch out", from: "Watch out! ") == "Watch out!")
    }

    @Test func bodyUnchangedWhenPaddedPassHasNoMark() {
        #expect(ParakeetEngine.withTerminalMark("Let me know", from: "Let me know") == "Let me know")
        #expect(ParakeetEngine.withTerminalMark("Let me know", from: "") == "Let me know")
        #expect(ParakeetEngine.withTerminalMark("Let me know", from: "Let me know,") == "Let me know")
    }

    @Test func alreadyPunctuatedTextSkipsTheSecondPass() {
        #expect(!ParakeetEngine.needsTerminalMark("Done."))
        #expect(!ParakeetEngine.needsTerminalMark("Really?"))
        #expect(!ParakeetEngine.needsTerminalMark(""))
        #expect(ParakeetEngine.needsTerminalMark("Not yet"))
        #expect(ParakeetEngine.withTerminalMark("Done.", from: "Done?") == "Done.")
    }
}
