import AVFoundation
import Foundation

/// Shared helper: resample mono Float32 samples to whisper's 16 kHz.
public enum AudioResampler {
    public static func to16kMono(_ samples: [Float], sourceRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let targetRate = Double(WhisperEngine.sampleRate)
        if sourceRate == targetRate { return samples }

        guard let sourceFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                  channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                  channels: 1, interleaved: false),
              let inBuffer = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else { return samples }

        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)

        let capacity = AVAudioFrameCount(Double(samples.count) * targetRate / sourceRate + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return samples
        }

        var fed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard convError == nil, let channel = outBuffer.floatChannelData else { return samples }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
    }
}
