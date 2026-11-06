import AppKit
import AVFoundation
import Carbon.HIToolbox
import SusurroCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Production capture: AVAudioEngine. Alternatives (raw CoreAudio HAL, ScreenCaptureKit)
    // were evaluated and rejected — see docs/history/PLAN.md ("mic-mode pill"); their
    // recorders were deleted in R0 and live on in git history.
    private let recorder = AudioRecorder()
    private let overlay = OverlayController()
    private let postProcessor = PostProcessor()
    private let models = ModelManager()
    private let toast = ToastPanel()
    private let helpWindow = HelpWindowController()

    private var cleaner: (any TextCleaning)?
    /// Typed façade over the UserDefaults keys; tuning constants (F9, R4).
    private let settings = Settings()
    private let tuning = Tuning.default
    // Self-tracking, not an Accessibility read — see docs/history/SMART_SPACING_PLAN.md.
    private let hotkey = HotkeyMonitor()

    // Hands-free (BEA-651). The machine decides; the rest is plumbing.
    private lazy var handsFree = tuning.makeHandsFreeMachine()
    private lazy var hfSession = HandsFreeSession(tuning: tuning)  // audio → chunks
    private var hfTimer: Timer?
    private var hfPID: pid_t?
    private var hfBundleID: String?
    private var hfAppObserver: NSObjectProtocol?
    /// One FIFO for every insertion, push-to-talk and hands-free (BEA-665, R3).
    private let insertionQueue = InsertionQueue()
    /// Keystrokes, clipboard/secure-input/app-switch policy and the
    /// self-tracked DictationMemory (BEA-665, R3).
    private let executor = InsertExecutor(inserter: KeystrokeInserter(), frontmost: SystemFrontmostApp(),
                                          clipboard: GeneralPasteboard())
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private lazy var engines: EngineController = {
        let c = EngineController(models: models, toast: toast, tuning: tuning)
        c.onStateChange = { [unowned self] in self.statusMenu.updateStatusIcon() }
        c.setStatus = { [unowned self] in self.statusMenu.setStatus($0) }
        c.clearStatus = { [unowned self] in self.statusMenu.clearStatus() }
        c.rebuildModelMenu = { [unowned self] in self.statusMenu.rebuildModelMenu() }
        c.hotkeyTitle = { [unowned self] in self.hotkey.key.title }
        return c
    }()
    private var engine: (any TranscriptionEngine)? { engines.engine }
    /// Transcribe-and-insert for every dictation, with the hands-free and
    /// cross-dictation join state (review F1/R4).
    private lazy var dictation = DictationController(
        engine: { [unowned self] in self.engine }, cleaner: { [unowned self] in self.cleaner },
        postProcessor: postProcessor, settings: settings, executor: executor, toast: toast)
    private lazy var statusMenu: StatusMenuController = {
        let m = StatusMenuController(models: models, toast: toast, hotkey: hotkey,
                                     engines: { [unowned self] in self.engines }, postProcessor: postProcessor,
                                     helpWindow: helpWindow, settings: settings)
        m.cleaner = { [unowned self] in self.cleaner }
        m.onSmartSpacingOff = { [unowned self] in self.executor.memory.clear() }
        return m
    }()
    private var axPollTimer: Timer?
    private lazy var devHooks = DevHooks(
        feed: { [unowned self] samples, pid, bundleID in
            self.insertionQueue.enqueue { [weak self] in
                await self?.dictation.transcribeAndInsert(samples, releasePID: pid, releaseBundleID: bundleID,
                                                expectedPID: nil, trigger: .devFeed)?.value
            }
        },
        probeInputs: { [unowned self] pid in
            .init(memory: self.executor.memory.insertionIfStillFocused(pid: pid), engine: self.engine?.kind,
                  smartSpacing: self.settings.smartSpacingEnabled, autoCapitalize: self.postProcessor.autoCapitalizeEnabled)
        })


    func applicationDidFinishLaunching(_ notification: Notification) {
        devHooks.install()
        if #available(macOS 26.0, *) {
            let cleaner = TranscriptCleaner()
            self.cleaner = cleaner
            if settings.llmCleanupEnabled {
                Task.detached { cleaner.prewarm() }
            }
        }
        statusMenu.build()

        setUpHotkey()

        // Request mic permission up front, decoupled from the first recording,
        // so the permission dialog can't interrupt an in-flight engine start.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.dictation.event("mic permission granted=\(granted)")
            if !granted {
                Task { @MainActor [weak self] in
                    self?.statusMenu.micDenied()
                }
            }
        }

        // Feed recorder levels to the overlay waveform (audio thread → main hop)
        recorder.levelHandler = { level in
            DispatchQueue.main.async { [weak self] in
                self?.overlay.push(level: level)
            }
        }

        // Mic unplugged / input device switched mid-recording: discard cleanly
        recorder.onInterruption = {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recorder.isRecording else { return }
                if self.hfTimer != nil {
                    // Hands-free: keep what was heard before the change.
                    self.handsFree.reset()
                    self.hfEnd(insert: true, reason: nil)
                    self.toast.show("Hands-free stopped — microphone changed")
                    Log.handsfree.event("interrupted by audio configuration change")
                    return
                }
                self.handsFree.reset()
                _ = self.recorder.stop()
                self.overlay.hide()
                self.toast.show("Recording interrupted — microphone changed")
                Log.dictation.event("recording interrupted by audio configuration change")
            }
        }

        engines.load()
    }

    // MARK: - Hotkey (push-to-talk)

    private func setUpHotkey() {
        hotkey.onPress = { [weak self] in guard let self else { return }; _ = self.hfEvent(.pttDown(at: self.now)) }
        hotkey.onRelease = { [weak self] in guard let self else { return }; _ = self.hfEvent(.pttUp(at: self.now)) }
        hotkey.onLatch = { [weak self] in guard let self else { return }; _ = self.hfEvent(.latchDown(at: self.now)) }
        hotkey.onEscape = { [weak self] in guard let self else { return false }; return self.hfEvent(.escape(at: self.now)) }

        if HotkeyMonitor.ensureAccessibility(prompt: true), hotkey.start() {
            hotkeyGranted()
        } else {
            Log.dictation.event("accessibility not granted yet — polling")
            statusMenu.setHotkeyStatus("grant Accessibility in System Settings")
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if HotkeyMonitor.ensureAccessibility(prompt: false), self.hotkey.start() {
                        self.axPollTimer?.invalidate()
                        self.axPollTimer = nil
                        self.hotkeyGranted()
                    }
                }
            }
        }
    }

    private func hotkeyGranted() {
        Log.dictation.event("event tap active")
        statusMenu.setHotkeyStatus("hold \(hotkey.key.title) to dictate")
    }

    private func pttPressed() {
        guard !recorder.isRecording else { return }
        guard engine != nil else {
            // Never ignore the key silently: say why nothing is happening.
            if let why = engines.unavailableMessage { toast.show(why) }
            return
        }
        do {
            try recorder.start()
            Log.dictation.event("recording")
            overlay.show()
        } catch {
            Log.dictation.failure("recorder.start failed: \(error)")
        }
    }

    private func pttReleased() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        overlay.hide()
        Log.dictation.event("stopped (\(samples.count) samples), transcribing")
        let releaseApp = NSWorkspace.shared.frontmostApplication
        let pid = releaseApp?.processIdentifier, bundleID = releaseApp?.bundleIdentifier
        // Queued behind any earlier dictation (PTT or a hands-free tail), so
        // quick releases type in order (BEA-665, F3).
        insertionQueue.enqueue { [weak self] in
            await self?.dictation.transcribeAndInsert(samples, releasePID: pid, releaseBundleID: bundleID,
                                            expectedPID: nil)?.value
        }
    }

    // MARK: - Hands-free (BEA-651)

    /// Feed the hands-free machine and carry out its effects. Returns whether
    /// the key event should be swallowed (only Esc while latched).
    private func hfEvent(_ event: HandsFreeMachine.Event) -> Bool {
        let out = handsFree.handle(event)
        for effect in out.effects { hfApply(effect) }
        return out.swallow
    }

    private func hfApply(_ effect: HandsFreeMachine.Effect) {
        switch effect {
        case .startRecording:
            pttPressed()
            if !recorder.isRecording { handsFree.reset() } // model not ready, mic failed
        case .latched:
            hfBegin()
        case .stopAndInsert(let reason):
            if hfTimer != nil { hfEnd(insert: true, reason: reason) } else { pttReleased() }
        case .cancel:
            hfEnd(insert: false, reason: nil)
        case .warnAutoStop(let reason, let remaining):
            overlay.setWarning(true)
            let secs = Int(remaining.rounded())
            toast.show(reason == .idle
                ? "No speech — hands-free stops in \(secs) s"
                : "Hands-free reaches its 2-hour limit in \(secs) s")
        }
    }

    private func hfBegin() {
        guard recorder.isRecording else { handsFree.reset(); return }
        let app = NSWorkspace.shared.frontmostApplication
        hfPID = app?.processIdentifier
        hfBundleID = app?.bundleIdentifier
        hfSession = HandsFreeSession(tuning: tuning)
        dictation.joiner = HeldMarkJoiner()
        dictation.prevChunk = nil
        overlay.setHandsFree(true)
        Log.handsfree.event("latched")
        hfTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.hfPump() }
        }
        hfAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.hfTimer != nil, pid != self.hfPID,
                      pid != ProcessInfo.processInfo.processIdentifier else { return }
                _ = self.hfEvent(.appSwitched(at: self.now))
            }
        }
    }

    /// Drain new audio, cut at pauses, queue finished chunks, drive auto-stop.
    private func hfPump() {
        guard hfTimer != nil else { return }
        let pump = hfSession.pump(recorder)
        pump.chunks.forEach(hfDispatch)
        if pump.heardSpeech {
            overlay.setWarning(false)
            _ = hfEvent(.heardSpeech(at: now))
        }
        _ = hfEvent(.tick(at: now))
    }

    private func hfDispatch(_ info: HFChunk) {
        let chunk = info.samples
        Log.handsfree.event("chunk \(chunk.count) samples")
        let generation = dictation.gate.token
        let pid = hfPID, bundleID = hfBundleID
        // Chunks are transcribed and typed strictly in order, in the same
        // queue as push-to-talk (BEA-665).
        insertionQueue.enqueue(isCurrent: { [weak self] in self?.dictation.gate.isCurrent(generation) ?? false }) {
            [weak self] in
            await self?.dictation.transcribeAndInsert(chunk, releasePID: pid, releaseBundleID: bundleID,
                                            expectedPID: pid, hfChunk: info, hfToken: generation)?.value
        }
    }

    private func hfEnd(insert: Bool, reason: HandsFreeMachine.StopReason?) {
        hfTimer?.invalidate()
        hfTimer = nil
        if let hfAppObserver { NSWorkspace.shared.notificationCenter.removeObserver(hfAppObserver) }
        hfAppObserver = nil
        if insert {
            let chunks = hfSession.finish(recorder)
            overlay.hide()
            chunks.forEach(hfDispatch)
            // After the last chunk is typed, type its held end mark (BEA-657),
            // only if the same app is still frontmost.
            let generation = dictation.gate.token
            let pid = hfPID
            insertionQueue.enqueue(isCurrent: { [weak self] in self?.dictation.gate.isCurrent(generation) ?? false }) {
                [weak self] in
                guard let self else { return }
                self.dictation.prevChunk = nil
                self.executor.typeHeldMark(self.dictation.joiner.stop(), sessionPID: pid)
            }
        } else {
            hfSession.discard(recorder)
            overlay.hide()
            dictation.gate.cancel() // drop chunks not yet typed, incl. one mid-transcription
            dictation.joiner.discard() // and the held mark with them
            dictation.prevChunk = nil
        }
        Log.handsfree.event("ended insert=\(insert) reason=\(String(describing: reason)) samples=\(hfSession.total)")
        switch reason {
        case .idle?: toast.show("Hands-free stopped — no speech for 60 s")
        case .safetyLimit?: toast.show("Hands-free stopped — 2-hour limit")
        case .appSwitched?: toast.show("Hands-free stopped — you switched apps")
        case nil where !insert: toast.show("Hands-free discarded")
        default: break
        }
    }

    // Menu bar icon stays static: the overlay waveform (and the system mic pill)
    // are the recording indicators — a third one was visual noise.

}

/// One hands-free chunk's audio plus where its speech starts/ends (relative
/// sample indices), kept so the next chunk can build a joint clip (BEA-657).
typealias HFChunk = DictationPipeline.ChunkAudio
