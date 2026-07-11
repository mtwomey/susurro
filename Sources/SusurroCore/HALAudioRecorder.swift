import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio via the CoreAudio HAL (AudioDeviceIOProc) —
/// the same low-level path classic recording tools use. Functionally identical
/// to AudioRecorder (in-memory 16 kHz mono Float32 out), but does not engage
/// the macOS "mic mode" menu bar pill that the modern input stack carries.
/// The orange privacy dot still shows — that indicator is universal.
public final class HALAudioRecorder: @unchecked Sendable {
    private var deviceID = AudioDeviceID(0)
    private var procID: AudioDeviceIOProcID?
    private var deviceSampleRate: Double = 48_000
    private var deviceChannels: Int = 1

    private var rawSamples: [Float] = []   // channel 0, device rate
    private let lock = NSLock()

    public private(set) var isRecording = false

    /// Peak level (0...1) per captured buffer — same hook as AudioRecorder.
    public var levelHandler: (@Sendable (Float) -> Void)?

    public init() {}

    public enum HALError: Error {
        case noInputDevice
        case formatQueryFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
    }

    public func start() throws {
        guard !isRecording else { return }

        // Default input device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != 0 else { throw HALError.noInputDevice }
        deviceID = device

        // Device input stream format (native rate/channels)
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw HALError.formatQueryFailed(status) }
        deviceSampleRate = format.mSampleRate
        deviceChannels = Int(format.mChannelsPerFrame)

        lock.lock()
        rawSamples.removeAll(keepingCapacity: true)
        lock.unlock()

        // IO proc — receives device-native Float32 buffers
        let context = Unmanaged.passUnretained(self).toOpaque()
        status = AudioDeviceCreateIOProcID(deviceID, { _, _, inInputData, _, _, _, clientData in
            guard let clientData, let inInputData else { return noErr }
            let recorder = Unmanaged<HALAudioRecorder>.fromOpaque(clientData).takeUnretainedValue()
            recorder.consume(bufferList: inInputData)
            return noErr
        }, context, &procID)
        guard status == noErr, let procID else { throw HALError.ioProcFailed(status) }

        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
            throw HALError.startFailed(status)
        }
        isRecording = true
    }

    /// Stops capture and returns 16 kHz mono samples, resampled from device rate.
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        isRecording = false

        lock.lock()
        let captured = rawSamples
        rawSamples = []
        lock.unlock()

        return Self.resampleTo16kMono(captured, sourceRate: deviceSampleRate)
    }

    private func consume(bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard let first = buffers.first(where: { $0.mData != nil }),
              let data = first.mData else { return }

        let channels = max(Int(first.mNumberChannels), 1)
        let totalFloats = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frames = totalFloats / channels
        guard frames > 0 else { return }

        let floats = data.assumingMemoryBound(to: Float.self)
        var mono = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        for frame in 0..<frames {
            let s = floats[frame * channels] // channel 0
            mono[frame] = s
            peak = max(peak, abs(s))
        }

        lock.lock()
        rawSamples.append(contentsOf: mono)
        lock.unlock()

        levelHandler?(min(peak, 1))
    }

    private static func resampleTo16kMono(_ samples: [Float], sourceRate: Double) -> [Float] {
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

        let outCapacity = AVAudioFrameCount(Double(samples.count) * targetRate / sourceRate + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
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
