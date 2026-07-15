import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// EXPERIMENTAL: captures the microphone via ScreenCaptureKit (macOS 15+ SCStream
/// microphone output) instead of a direct mic input session.
///
/// Why this exists: a true mic input session gets a `mic:` attribution and triggers
/// Control Center's mic-modes pill in the menu bar. SCK capture is attributed as
/// `aud`/`scr` and does not (see docs/PLAN.md "mic-mode pill"). The trade-offs:
///   - Requires the Screen Recording TCC permission (display content filter)
///   - Stream startup is an async daemon negotiation — audio spoken before the
///     stream is live is LOST. This class logs keypress→first-sample latency.
///   - Capture runs out-of-process with IPC delivery (small CPU/latency overhead).
public final class SCKAudioRecorder: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var samples: [Float] = []
    private var sourceRate: Double = 48_000
    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(label: "susurro.sck.audio")

    public private(set) var isRecording = false
    private var startRequestedAt: Date?
    private var firstSampleSeen = false

    public var levelHandler: (@Sendable (Float) -> Void)?

    public enum SCKError: Error {
        case noDisplay
    }

    /// Returns immediately; capture becomes live once the SCK daemon negotiation
    /// completes (measured and logged). Audio before that moment is lost.
    public func start() throws {
        guard !isRecording else { return }
        isRecording = true
        firstSampleSeen = false
        startRequestedAt = Date()
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            do {
                let t0 = Date()
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let display = content.displays.first else { throw SCKError.noDisplay }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = false        // no system audio
                config.captureMicrophone = true     // macOS 15+
                config.width = 2                    // minimal video (filter is mandatory)
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
                config.showsCursor = false

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                self.stream = stream
                NSLog("[susurro] SCK: startCapture completed %.0f ms after keypress",
                      -t0.timeIntervalSinceNow * 1000)
            } catch {
                NSLog("[susurro] SCK: start FAILED: %@", String(describing: error))
                self.isRecording = false
            }
        }
    }

    public func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil

        lock.lock()
        let captured = samples
        samples = []
        let rate = sourceRate
        lock.unlock()
        return AudioResampler.to16kMono(captured, sourceRate: rate)
    }
}

extension SCKAudioRecorder: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .microphone, isRecording,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription
        else { return }

        if !firstSampleSeen {
            firstSampleSeen = true
            if let t = startRequestedAt {
                NSLog("[susurro] SCK: FIRST mic sample %.0f ms after keypress",
                      -t.timeIntervalSinceNow * 1000)
            }
        }

        lock.lock()
        sourceRate = asbd.mSampleRate
        lock.unlock()

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let buffer = audioBufferList.first(where: { $0.mData != nil }),
                      let data = buffer.mData else { return }
                // SCK delivers Float32; non-interleaved = first buffer is channel 0
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { return }
                let floats = data.assumingMemoryBound(to: Float.self)

                var peak: Float = 0
                var chunk = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    chunk[i] = floats[i]
                    peak = max(peak, abs(floats[i]))
                }
                lock.lock()
                samples.append(contentsOf: chunk)
                lock.unlock()
                levelHandler?(min(peak, 1))
            }
        } catch {
            NSLog("[susurro] SCK: buffer extraction failed: %@", String(describing: error))
        }
    }
}
