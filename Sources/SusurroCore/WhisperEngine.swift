import CWhisper
import Foundation

public enum WhisperError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)

    public var description: String {
        switch self {
        case .modelLoadFailed(let path): "failed to load whisper model at \(path)"
        case .transcriptionFailed(let code): "whisper_full failed with code \(code)"
        }
    }
}

/// In-process whisper.cpp engine. Loads the model once and stays warm.
/// Expects 16 kHz mono Float32 samples.
/// @unchecked Sendable: whisper_context is not reentrant, so transcribe() is
/// internally serialized — two quick dictations can't corrupt the context.
public final class WhisperEngine: @unchecked Sendable {
    public static let sampleRate = 16_000

    private let ctx: OpaquePointer
    private let transcribeLock = NSLock()

    public init(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
    }

    deinit {
        whisper_free(ctx)
    }

    public func transcribe(samples: [Float]) throws -> String {
        transcribeLock.lock()
        defer { transcribeLock.unlock() }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress   = false
        params.print_realtime   = false
        params.print_special    = false
        params.print_timestamps = false
        params.no_timestamps    = true
        params.suppress_blank   = true
        params.n_threads        = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))

        let rc = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { throw WhisperError.transcriptionFailed(rc) }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            text += String(cString: whisper_full_get_segment_text(ctx, i))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
