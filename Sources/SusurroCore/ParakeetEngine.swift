import FluidAudio
import Foundation

/// Spike-grade wrapper around FluidAudio's Parakeet TDT ASR (BEA-632).
/// Not yet wired into the app; see docs/PARAKEET_PLAN.md.
public final class ParakeetEngine {
    private let manager: AsrManager

    private init(manager: AsrManager) {
        self.manager = manager
    }

    /// Downloads (if missing) and loads Parakeet TDT 0.6B v2 Core ML models.
    public static func load() async throws -> ParakeetEngine {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        return ParakeetEngine(manager: manager)
    }

    public static var modelDirectory: URL { AsrModels.defaultCacheDirectory(for: .v2) }

    /// 16 kHz mono Float32 samples, same contract as WhisperEngine.
    public func transcribe(samples: [Float]) async throws -> String {
        try await manager.transcribe(samples, source: .microphone).text
    }
}
