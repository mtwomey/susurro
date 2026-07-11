import AVFoundation
import Foundation

/// Captures microphone audio into an in-memory 16 kHz mono Float32 buffer —
/// whisper's input format. No temp files, no external processes.
public final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    public private(set) var isRecording = false

    /// Called with the peak level (0...1) of each captured buffer — feeds the overlay waveform later.
    public var levelHandler: (@Sendable (Float) -> Void)?

    /// Fired if the audio graph changes while recording (mic unplugged, default
    /// input device switched). The recording is no longer trustworthy.
    public var onInterruption: (@Sendable () -> Void)?

    private var configObserver: NSObjectProtocol?

    public init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.onInterruption?()
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    public func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperEngine.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw AudioFileLoaderError.conversionFailed }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil

        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        return captured
    }

    private func process(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard convError == nil, let channel = out.floatChannelData else { return }

        let converted = UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()

        if let levelHandler {
            var peak: Float = 0
            for s in converted { peak = max(peak, abs(s)) }
            levelHandler(min(peak, 1))
        }
    }
}
