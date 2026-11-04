import FluidAudio
import Foundation

public enum ParakeetEngineError: Error, CustomStringConvertible {
    case modelFilesMissing(String)

    public var description: String {
        switch self {
        case .modelFilesMissing(let path): "Parakeet model files missing or incomplete at \(path)"
        }
    }
}

/// NVIDIA Parakeet TDT 0.6B v2 (English) through FluidAudio's Core ML
/// `AsrManager`. Apple Silicon only (the catalog hides it elsewhere).
///
/// Honours the `TranscriptionEngine` contract:
/// - **Warm load:** `init(modelDirectory:)` loads the Core ML models from a
///   Susurro-owned directory (`ModelManager` downloads it; see
///   docs/PARAKEET_PLAN.md) and initializes the manager once. Nothing is
///   downloaded and nothing is written to FluidAudio's own cache.
/// - **Serialized:** `AsrManager` is a non-`Sendable` class with mutable
///   decoder state, so every call into it goes through `lock`, one at a time.
///   That is what justifies `@unchecked Sendable`.
/// - **Sync bridge:** FluidAudio's API is async while the protocol is sync (the
///   app calls it from a detached task, the CLI from top-level code). Each call
///   runs the async work in a detached task and blocks the caller until done.
public final class ParakeetEngine: TranscriptionEngine, @unchecked Sendable {
    public static let sampleRate = 16_000
    public var kind: EngineKind { .parakeet }

    /// FluidAudio rejects buffers under one second (`ASRError.invalidAudioData`);
    /// short push-to-talk taps are padded with silence up to this length.
    static let minimumSamples = 16_000

    /// Silence appended after every utterance. Push-to-talk ends the buffer
    /// right at the last word, and Parakeet TDT only emits the final ? or .
    /// once it hears trailing silence. Without it, a one-sentence dictation
    /// comes out with no punctuation at all ("Hey are you coming to lunch
    /// today"). Measured with susurro-cli: 0.5 s, 1 s and 2 s all restore the
    /// mark; 0.5 s is used (0.3 s and 0.75 s each hallucinated a trailing "Yeah." on Fixtures/clip1.wav); it costs ~10 ms at Parakeet's speed.
    static let trailingSilenceSamples = 8_000

    private let manager: ManagerBox
    private let lock = NSLock()

    /// Loads the v2 models from `modelDirectory` (the
    /// `parakeet-tdt-0.6b-v2-coreml` folder). Blocking, and slow on first use
    /// (Core ML compile); call it off the main thread.
    public init(modelDirectory: URL) throws {
        // AsrModels.load(from:) silently re-downloads (~450 MB) when files are
        // missing. A broken model directory must fail the load instead
        // ("Model load failed"); downloading is ModelManager's job.
        guard AsrModels.modelsExist(at: modelDirectory, version: .v2) else {
            throw ParakeetEngineError.modelFilesMissing(modelDirectory.path)
        }
        manager = try Self.runBlocking {
            let models = try await AsrModels.load(from: modelDirectory, version: .v2)
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            return ManagerBox(manager)
        }
    }

    /// Dev-harness path (parakeet-spike): download into FluidAudio's cache if
    /// missing, then load. The app never uses this.
    public static func downloadAndLoad() throws -> ParakeetEngine {
        let directory = fluidAudioCacheDirectory
        if !AsrModels.modelsExist(at: directory, version: .v2) {
            _ = try runBlocking { _ = try await AsrModels.download(version: .v2) }
        }
        return try ParakeetEngine(modelDirectory: directory)
    }

    public static var fluidAudioCacheDirectory: URL { AsrModels.defaultCacheDirectory(for: .v2) }

    public func transcribe(samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        let input = Self.padded(samples)
        let manager = self.manager
        lock.lock()
        defer { lock.unlock() }
        let text = try Self.runBlocking {
            try await manager.value.transcribe(input, source: .microphone).text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appends `trailingSilenceSamples` of silence, then pads to FluidAudio's
    /// one-second minimum if the result is still shorter.
    static func padded(_ samples: [Float]) -> [Float] {
        let target = max(samples.count + trailingSilenceSamples, minimumSamples)
        return samples + [Float](repeating: 0, count: target - samples.count)
    }

    // MARK: - async -> sync bridge

    /// Carries the non-`Sendable` manager across task boundaries. Access is
    /// serialized by the owning engine's lock.
    private final class ManagerBox: @unchecked Sendable {
        let value: AsrManager
        init(_ value: AsrManager) { self.value = value }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private static func runBlocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}
