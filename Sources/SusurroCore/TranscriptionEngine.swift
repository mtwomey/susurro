import Foundation

/// A speech-to-text engine the app and CLI can drive without knowing which
/// backend sits behind it.
///
/// Contract every conforming engine must honour:
/// - **Warm load.** Construction loads the model fully; an instance that
///   exists is ready to transcribe, and stays warm for its lifetime. Loading
///   may be slow, so callers construct engines off the main thread.
/// - **Input.** 16 kHz (`sampleRate`) mono Float32 samples.
/// - **Serialized.** `transcribe(samples:)` is safe to call from any thread;
///   concurrent calls are serialized internally, never interleaved. That is
///   what makes conformers `Sendable` even when the backend is not reentrant.
/// - **Output.** Plain text with surrounding whitespace trimmed; filtering and
///   post-processing stay with the caller.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Sample rate, in Hz, that `transcribe(samples:)` expects.
    static var sampleRate: Int { get }

    /// Which backend this is, so engine-specific output filtering
    /// (`TranscriptFilter`) can be applied by the caller.
    var kind: EngineKind { get }

    func transcribe(samples: [Float]) throws -> String
}

/// The single place that knows which concrete engine backs a model, so the
/// app and CLI depend on `TranscriptionEngine` only.
public enum TranscriptionEngines {
    /// Sample rate shared by every engine (16 kHz mono).
    public static let sampleRate = WhisperEngine.sampleRate

    /// Loads (warm) the engine for the model at `modelPath`: a ggml file runs
    /// on whisper.cpp, a Core ML model directory on Parakeet. Pass `engine`
    /// when the catalog kind is known; otherwise it is inferred from the path.
    /// Blocking and potentially slow; call it off the main thread.
    public static func load(modelPath: String, engine: EngineKind? = nil) throws -> any TranscriptionEngine {
        switch engine ?? kind(ofPath: modelPath) {
        case .whisper: return try WhisperEngine(modelPath: modelPath)
        case .parakeet: return try ParakeetEngine(modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true))
        }
    }

    /// Directory = Core ML (Parakeet), anything else = ggml file (whisper).
    public static func kind(ofPath path: String) -> EngineKind {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue ? .parakeet : .whisper
    }
}
