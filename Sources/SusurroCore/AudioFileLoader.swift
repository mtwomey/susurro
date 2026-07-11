import AVFoundation
import Foundation

public enum AudioFileLoaderError: Error {
    case unreadable(URL)
    case conversionFailed
}

/// Loads any audio file and converts it to 16 kHz mono Float32 — whisper's input format.
public enum AudioFileLoader {
    public static func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperEngine.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw AudioFileLoaderError.conversionFailed }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw AudioFileLoaderError.unreadable(url) }
        try file.read(into: sourceBuffer)

        // Already in target format — no conversion needed
        if sourceFormat == targetFormat, let data = sourceBuffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(sourceBuffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileLoaderError.conversionFailed
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up) + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AudioFileLoaderError.conversionFailed
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
            return sourceBuffer
        }
        if let convError { throw convError }

        guard let data = outBuffer.floatChannelData else { throw AudioFileLoaderError.conversionFailed }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(outBuffer.frameLength)))
    }
}
