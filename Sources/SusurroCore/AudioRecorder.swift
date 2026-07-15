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

    // Prototype: Apple Voice Processing I/O (AEC/noise suppression/AGC). When true,
    // start() taps engine.inputNode directly (same mechanism as the plain path — no
    // AVAudioMixerNode, no AVAudioSinkNode, no connection to mainMixerNode/outputNode
    // is ever created) but at the input node's own native VP format instead of forcing
    // a target format on the tap. Enabling voice processing makes the input node
    // report a non-standard multichannel format (observed: 9 channels @ 48 kHz).
    // Earlier attempts fed that whole 9-channel buffer through AVAudioMixerNode's or
    // AVAudioConverter's automatic channel-downmix and got exactly 0.0 peak back on
    // every buffer, across every render-graph wiring tried (mixer, sink node,
    // mainMixerNode) — strong evidence the *automatic* downmix matrix for this
    // unrecognized/discrete 9-channel layout collapses to silence, independent of
    // where the graph terminates. This path avoids that matrix entirely: it inspects
    // all 9 raw channels of each tapped buffer itself, manually copies whichever
    // channel currently carries the highest peak into a plain mono buffer (no mixing,
    // no matrix), and only then hands that to the same AVAudioConverter + process()
    // the plain path uses, for the sample-rate step to 16 kHz. See docs/PLAN.md for
    // why capture must stay on AVAudioEngine's inputNode (ScreenCaptureKit was
    // rejected for mic-pill reasons).
    public var voiceProcessingEnabled: Bool = false

    /// Called with the peak level (0...1) of each captured buffer — feeds the overlay waveform later.
    public var levelHandler: (@Sendable (Float) -> Void)?

    /// Fired if the audio graph changes while recording (mic unplugged, default
    /// input device switched). The recording is no longer trustworthy.
    public var onInterruption: (@Sendable () -> Void)?

    private var configObserver: NSObjectProtocol?

    // True only while a voice-processing-enabled recording is active. stop() uses
    // this (rather than re-reading `voiceProcessingEnabled`) to decide which teardown
    // to run, so it stays correct even if the flag is flipped after start() was called.
    // The VP path installs its tap directly on engine.inputNode (see startVoiceProcessing),
    // so there is no separate mixer/sink node to track here anymore.
    private var isVoiceProcessingActive = false

    // Mirrors what's actually been applied to engine.inputNode via
    // setVoiceProcessingEnabled, which is NOT the same as `voiceProcessingEnabled`
    // (the desired/toggled state) at every instant. start() reconciles the two,
    // applying setVoiceProcessingEnabled only when they differ — measured to cost
    // ~250-400ms, so doing it on every single recording (as an earlier version of
    // this fix did, toggling it on in start() and off in stop() every time) made
    // every push-to-talk press that much slower. Toggling the feature is rare;
    // starting a recording is not, so the cost belongs on the former.
    private var appliedVoiceProcessingState = false

    // Set once, on the first buffer of a VP recording, and reused for every
    // subsequent buffer in that same recording — rather than independently
    // re-picking "whichever channel is loudest" on every buffer. On the hardware
    // this was validated against, all 9 VP channels reported identical content
    // (likely a duplicated/broadcast layout), so per-buffer reselection made no
    // difference there — but on hardware where the channels genuinely differ,
    // re-picking per buffer could hop between channels and click at each switch.
    // Reset to nil at the start of each recording in startVoiceProcessing().
    private var pinnedVPChannel: Int?

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

        // Reconcile the underlying audio unit's VP state with the desired one, only
        // when they actually differ (i.e. the feature was toggled since the last
        // recording) — see appliedVoiceProcessingState. Safe to call here: the engine
        // is always stopped at this point (either never started, or stop() left it
        // stopped), and Apple's docs require voice processing to only be toggled
        // while the engine is stopped.
        if voiceProcessingEnabled != appliedVoiceProcessingState {
            try engine.inputNode.setVoiceProcessingEnabled(voiceProcessingEnabled)
            appliedVoiceProcessingState = voiceProcessingEnabled

            // Voice processing normally ducks other apps' audio while it's engaged
            // (like FaceTime/Siri dictation do) -- and since it now stays enabled
            // continuously across recordings rather than being re-toggled per press
            // (see appliedVoiceProcessingState above), that duck was never lifting
            // between key presses, only when the feature was toggled off entirely.
            // Minimizing the ducking level directly, rather than reverting to
            // per-recording enable/disable, keeps the latency fix intact.
            if voiceProcessingEnabled {
                var duckingConfig = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
                duckingConfig.duckingLevel = .min
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = duckingConfig
            }
        }

        if voiceProcessingEnabled {
            try startVoiceProcessing()
        } else {
            try startPlain()
        }
    }

    /// Stops capture and returns everything recorded since `start()`.
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        let wasVoiceProcessing = isVoiceProcessingActive

        engine.inputNode.removeTap(onBus: 0)
        if wasVoiceProcessing {
            isVoiceProcessingActive = false
        }

        engine.stop()
        isRecording = false
        converter = nil

        // Deliberately does NOT disable voice processing here. It stays applied on
        // engine.inputNode across recordings — see appliedVoiceProcessingState — and
        // is only ever turned off by start() the next time voiceProcessingEnabled is
        // actually false and differs from what's applied (i.e. the user toggled the
        // feature off), or by the failure-cleanup paths in startVoiceProcessing().

        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        return captured
    }

    // MARK: - Plain (non-voice-processing) path
    //
    // Textually identical to the original start() body (statements, order, and
    // arguments unchanged) — only relocated into its own method. When
    // voiceProcessingEnabled is false, this is the only code that runs: no
    // AVAudioMixerNode is ever created/attached/connected, and no VP-related engine
    // state (setVoiceProcessingEnabled, mainMixerNode.outputVolume) is ever touched.
    private func startPlain() throws {
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

    // MARK: - Voice-processing path
    //
    // Entirely additive; only reachable when voiceProcessingEnabled == true.
    //
    // Iterations 1-4 all routed the VP-format buffer through AVAudioMixerNode's or
    // AVAudioConverter's automatic multichannel-downmix (mixer -> mainMixerNode,
    // mixer -> AVAudioSinkNode, with/without mute flags, with/without explicit device
    // selection) and got exactly 0.0 peak back on every buffer, every time, across
    // every graph wiring — while an even earlier raw-tap-with-no-downmix-at-all
    // experiment (before any mixer/sink existed) saw non-exactly-zero, if very
    // quiet, values on the raw channels. The common thread across every zero-signal
    // result is that something was asked to *mix down* the 9 channels to 1 using an
    // automatic channel matrix. AVAudioFormat(channels: 9) with no explicit
    // AVAudioChannelLayout produces an "unspecified/discrete" layout, and both
    // AVAudioMixerNode and AVAudioConverter are documented to fall back to
    // conservative (often silent) behavior for channel maps they don't recognize.
    // This iteration removes the automatic downmix entirely: it taps
    // engine.inputNode directly at its own native (odd) VP format — exactly like
    // the plain path taps it at its own native format, no mixer/sink node, no
    // connection to mainMixerNode/outputNode at all — then in the tap callback
    // manually inspects every raw channel's peak and copies (not mixes) whichever
    // channel currently has the most signal into a genuine mono buffer, which is
    // the only thing handed to AVAudioConverter (for the sample-rate step only,
    // 1ch -> 1ch, so its own channel-matrix logic is never invoked either).
    private func startVoiceProcessing() throws {
        // Voice processing is already applied to engine.inputNode by this point —
        // see the reconciliation in start(). Not re-applied here, since that's the
        // per-recording cost this method used to pay on every single call.
        let input = engine.inputNode

        let vpFormat = input.outputFormat(forBus: 0)
        guard vpFormat.sampleRate > 0, vpFormat.channelCount > 0 else {
            revertVoiceProcessingAfterFailure()
            throw AudioFileLoaderError.conversionFailed
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperEngine.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            revertVoiceProcessingAfterFailure()
            throw AudioFileLoaderError.conversionFailed
        }

        // Only ever used as the *destination* of a manual per-sample channel copy
        // (see extractLoudestChannel below) — never as the output format of a
        // mixer/converter channel-mixing step. That's the whole point of this
        // iteration: no automatic downmix matrix touches this format.
        guard let nativeMonoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: vpFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            revertVoiceProcessingAfterFailure()
            throw AudioFileLoaderError.conversionFailed
        }

        converter = AVAudioConverter(from: nativeMonoFormat, to: targetFormat)
        pinnedVPChannel = nil

        // Tapped at vpFormat (the input node's own native, odd, multichannel
        // format) — mirrors exactly how startPlain() taps inputNode at its own
        // native format. No AVAudioMixerNode/AVAudioSinkNode is attached, and
        // nothing is ever connected to mainMixerNode/outputNode, so this cannot
        // reproduce the "kAUInitialize on real hardware output" throw seen in
        // earlier iterations — that only ever happened once something was wired
        // to the real output AU.
        input.installTap(onBus: 0, bufferSize: 4096, format: vpFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let mono = self.extractLoudestChannel(from: buffer, monoFormat: nativeMonoFormat) else { return }
            self.process(buffer: mono, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            revertVoiceProcessingAfterFailure()
            throw error
        }
        isVoiceProcessingActive = true
        isRecording = true
    }

    // Used by startVoiceProcessing()'s failure paths to undo an enable that just
    // failed to actually produce a usable recording — keeps appliedVoiceProcessingState
    // truthful so the next start() call knows voice processing isn't really applied
    // and will retry enabling it, rather than assuming it's already on.
    private func revertVoiceProcessingAfterFailure() {
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        appliedVoiceProcessingState = false
    }

    // Inspects every channel of a raw VP-format buffer and manually memcpy's the
    // selected channel's samples into a fresh single-channel buffer. Deliberately
    // does NOT sum/average/matrix-mix channels together — any such mixing is
    // exactly the step that produced exactly 0.0 peak in every prior iteration, so
    // this always picks exactly one real channel's real samples, verbatim. The
    // channel is chosen once (loudest on the first buffer) and pinned for the rest
    // of the recording via pinnedVPChannel, rather than reselected every buffer.
    private func extractLoudestChannel(
        from buffer: AVAudioPCMBuffer,
        monoFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0, let raw = buffer.floatChannelData else { return nil }

        let channel: Int
        if let pinned = pinnedVPChannel {
            channel = pinned
        } else {
            var bestChannel = 0
            var bestPeak: Float = -1
            for ch in 0..<channelCount {
                let data = raw[ch]
                var peak: Float = 0
                for i in 0..<frameLength { peak = max(peak, abs(data[i])) }
                if peak > bestPeak {
                    bestPeak = peak
                    bestChannel = ch
                }
            }
            channel = bestChannel
            pinnedVPChannel = bestChannel
        }

        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
              let dest = mono.floatChannelData else { return nil }
        mono.frameLength = buffer.frameLength
        memcpy(dest[0], raw[channel], frameLength * MemoryLayout<Float>.size)
        return mono
    }

    // Unchanged. Generic over source format — doesn't know or care whether `buffer`
    // came from the input node directly (plain path) or from the manually-copied
    // loudest-channel mono buffer (VP path); both feed the same 16 kHz mono
    // Float32 `samples` array.
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
