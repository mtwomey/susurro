import AppKit
import AVFoundation
import Carbon.HIToolbox
import SusurroCore

func slog(_ msg: String) {
    NSLog("[susurro] %@", msg)
}

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
    private var cleanupEnabled: Bool {
        get { settings.llmCleanupEnabled }
        set { settings.llmCleanupEnabled = newValue }
    }

    private var copyToClipboard: Bool {
        get { settings.copyToClipboard } // default off
        set { settings.copyToClipboard = newValue }
    }
    private var smartSpacingEnabled: Bool {
        get { settings.smartSpacingEnabled } // default off
        set { settings.smartSpacingEnabled = newValue }
    }
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
    // Cancel (Esc) moves the gate on: queued chunks are dropped, and a chunk
    // already mid-transcription is dropped at insert time (BEA-663, F2).
    private var hfGate = SessionGate()
    // Hands-free joins (BEA-657): each chunk's final end mark is held back and
    // decided from a joint transcript across the pause when the next chunk lands.
    private var hfJoiner = HeldMarkJoiner()
    private var hfPrevChunk: HFChunk?       // audio of the chunk whose mark is held
    /// Cross-dictation joins (BEA-677): the previous push-to-talk insertion
    /// and its audio, kept so the next dictation can decide its full stop.
    private var xPrev: (record: CrossDictationJoin.Previous, samples: [Float], lastSpeech: Int)?
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
                await self?.transcribeAndInsert(samples, releasePID: pid, releaseBundleID: bundleID,
                                                expectedPID: nil)?.value
            }
        },
        probeInputs: { [unowned self] pid in
            .init(memory: self.executor.memory.insertionIfStillFocused(pid: pid), engine: self.engine?.kind,
                  smartSpacing: self.smartSpacingEnabled, autoCapitalize: self.postProcessor.autoCapitalizeEnabled)
        })


    func applicationDidFinishLaunching(_ notification: Notification) {
        devHooks.install()
        if #available(macOS 26.0, *) {
            let cleaner = TranscriptCleaner()
            self.cleaner = cleaner
            if cleanupEnabled {
                Task.detached { cleaner.prewarm() }
            }
        }
        statusMenu.build()

        setUpHotkey()

        // Request mic permission up front, decoupled from the first recording,
        // so the permission dialog can't interrupt an in-flight engine start.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            slog("mic permission granted=\(granted)")
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
                    slog("handsfree: interrupted by audio configuration change")
                    return
                }
                self.handsFree.reset()
                _ = self.recorder.stop()
                self.overlay.hide()
                self.toast.show("Recording interrupted — microphone changed")
                slog("recording interrupted by audio configuration change")
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
            slog("accessibility not granted yet — polling")
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
        slog("event tap active")
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
            slog("ptt: recording")
            overlay.show()
        } catch {
            slog("ptt: recorder.start failed: \(error)")
        }
    }

    private func pttReleased() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        overlay.hide()
        slog("ptt: stopped (\(samples.count) samples), transcribing")
        let releaseApp = NSWorkspace.shared.frontmostApplication
        let pid = releaseApp?.processIdentifier, bundleID = releaseApp?.bundleIdentifier
        // Queued behind any earlier dictation (PTT or a hands-free tail), so
        // quick releases type in order (BEA-665, F3).
        insertionQueue.enqueue { [weak self] in
            await self?.transcribeAndInsert(samples, releasePID: pid, releaseBundleID: bundleID,
                                            expectedPID: nil)?.value
        }
    }

    /// Transcribe `samples` and insert the result into the focused field.
    /// `expectedPID` (hands-free chunks): if another app is frontmost by the
    /// time the text is ready, it goes to the clipboard instead of being typed
    /// into the wrong app. nil = today's push-to-talk behaviour, unchanged.
    @discardableResult
    private func transcribeAndInsert(_ samples: [Float], releasePID: pid_t?, releaseBundleID: String?,
                                     expectedPID: pid_t?, hfChunk: HFChunk? = nil,
                                     hfToken: Int? = nil) -> Task<Void, Never>? {
        guard let engine else { return nil }
        let postProcessor = postProcessor
        // Transcript side of the dictation (BEA-664, R2): the same pipeline
        // susurro-cli runs, so the eval harness exercises this code.
        let pipeline = DictationPipeline(engine: engine, postProcessor: postProcessor,
                                         cleaner: cleanupEnabled ? self.cleaner : nil)
        // Text handling (BEA-648): read the focused field through
        // Accessibility while the engine transcribes; capped at 250 ms.
        // Smart Spacing is the stage's master toggle — off means no read and
        // the old context-free behaviour (sentence case only).
        var fieldTask: Task<(FieldSnapshot?, Duration), Never>?
        if smartSpacingEnabled, !IsSecureEventInputEnabled(), let pid = releasePID {
            fieldTask = Task.detached(priority: .userInitiated) {
                let clock = ContinuousClock(), start = clock.now
                let snapshot = await FocusedFieldReader.read(pid: pid, bundleID: releaseBundleID)
                return (snapshot, clock.now - start)
            }
        }
        let pendingFieldRead = fieldTask
        return Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            var timings = StageTimings()
            let transcript: String
            let transcribeStart = clock.now
            do {
                transcript = try engine.transcribe(samples: samples)
            } catch {
                slog("ptt: transcription FAILED: \(error)")
                await MainActor.run { [weak self] in
                    self?.toast.show("Transcription failed — see log")
                }
                transcript = ""
            }
            timings.transcribe = clock.now - transcribeStart
            let raw = TranscriptFilter.stripHallucinations(transcript, engine: engine.kind)
            // Sentence case is deferred to the pre-insert stage, which can see
            // what precedes the cursor.
            let cleaned = await pipeline.cleanDictation(transcript)
            slog("ptt: transcript: \(raw) -> \(cleaned)")
            let fieldResult = await pendingFieldRead?.value
            let fieldRead = fieldResult?.0
            timings.axRead = fieldResult?.1
            let autoCapitalize = postProcessor.autoCapitalizeEnabled
            // Hands-free joins (BEA-657): hold this chunk's final mark; if the
            // previous chunk's mark is held, decide it from a joint transcript.
            var hfStep: DictationPipeline.HandsFreeStep?
            if let hfChunk, !cleaned.isEmpty {
                let step = await MainActor.run { [weak self] () -> (HeldMarkJoiner.Plan, HFChunk?)? in
                    // Cancelled while this chunk was transcribing: leave the
                    // joiner alone (it may already belong to a new session).
                    guard let self, self.hfGate.isCurrent(hfToken) else { return nil }
                    let previous = self.hfPrevChunk
                    let plan = self.hfJoiner.accept(cleaned, pid: expectedPID)
                    self.hfPrevChunk = hfChunk
                    return (plan, previous)
                }
                if let step {
                    var jointTime: Duration?
                    hfStep = try? pipeline.handsFreeStep(step.0, previous: step.1, current: hfChunk,
                                                         jointSeconds: &jointTime, failedJointAsEmpty: true)
                    if let jointTime { timings.joinTranscribe = jointTime }
                    if case .joined(let held, let decision, _, _)? = hfStep {
                        slog("handsfree: join decision=\(decision) held=\(held.mark)")
                    }
                }
            }
            let processed = hfStep?.pieceText(cleaned: cleaned) ?? cleaned
            // Cross-dictation join (BEA-677): a separate dictation right after
            // Susurro's previous one. Decide the previous full stop from a
            // joint clip now; the field guards run before insertion.
            let startedAt = Date().addingTimeInterval(-Double(samples.count) / 16_000)
            var xDecision: HandsFreeJoin.Decision?
            if hfChunk == nil, !processed.isEmpty {
                let prev = await MainActor.run { [weak self] in self?.xPrev }
                var jointTime: Duration?
                xDecision = try? pipeline.crossDecision(
                    previous: prev?.record,
                    previousAudio: prev.map { .init(samples: $0.samples, firstSpeech: 0, lastSpeech: $0.lastSpeech) },
                    samples: samples, pid: releasePID, startedAt: startedAt,
                    jointSeconds: &jointTime, failedJointAsEmpty: true)
                if let jointTime { timings.joinTranscribe = jointTime }
            }
            let crossDecision = xDecision
            let join = InsertPlan.Join(hfStep)
            let joinText = join.joinedText
            let isHandsFree = hfChunk != nil
            let stageTimings = timings
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.hfGate.isCurrent(hfToken) else {
                    slog("handsfree: chunk dropped — session cancelled during transcription")
                    return
                }
                guard !processed.isEmpty || joinText != nil else { return }
                // Secure input (password fields) silently blocks synthetic typing —
                // in that case copy regardless of the setting so the words aren't lost.
                let secureInputActive = IsSecureEventInputEnabled()
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if let expectedPID, frontmostPID != expectedPID {
                    // Hands-free chunk finished after an app switch: never type
                    // it somewhere the user didn't dictate into.
                    // A held mark travels with the copied words, never lost.
                    // (A mark already shown in the old field stays there.)
                    let copied = InsertPlan.appSwitchClipboardText(processed: processed, join: join)
                    let message = self.executor.copyAfterAppSwitch(copied)
                    self.hfJoiner.discard()
                    self.toast.show(message)
                    slog("handsfree: chunk after app switch -> clipboard")
                    return
                }
                // Pre-insert text-handling stage (docs/TEXT_HANDLING_FINDINGS.md):
                // Accessibility read of the focused field, self-tracked memory as
                // the fallback, unknown = empty field. The AX read only counts if
                // the same app is still frontmost. Field text is never logged.
                let context: InsertContext
                var provider = "off"
                if self.smartSpacingEnabled {
                    let sameApp = frontmostPID != nil && frontmostPID == releasePID
                    let resolved = InsertContext.resolve(
                        snapshot: sameApp ? fieldRead : nil,
                        memory: frontmostPID.flatMap { self.executor.memory.insertionIfStillFocused(pid: $0) },
                        pid: frontmostPID, bundleID: releaseBundleID, engine: engine.kind,
                        secureInput: secureInputActive)
                    context = resolved.0
                    provider = resolved.1
                } else {
                    context = InsertContext(before: nil, source: .none, pid: frontmostPID,
                                            engine: engine.kind, secureInput: secureInputActive)
                }
                let stage = TextHandlingStage.standard(smartSpacing: self.smartSpacingEnabled,
                                                       autoCapitalize: autoCapitalize)
                // The insert decisions are pure (SusurroCore InsertPlan,
                // BEA-664); this block only gathers facts and carries them out.
                let plan = InsertPlan.make(
                    processed: processed, join: join, isHandsFree: isHandsFree,
                    expectedPID: expectedPID, frontmostPID: frontmostPID,
                    context: context, stage: stage, secureInput: secureInputActive,
                    heldMark: self.hfJoiner.held?.mark,
                    cross: self.xPrev.map { ($0.record, crossDecision) },
                    startedAt: startedAt, fieldValue: fieldRead?.value)
                plan.notes.forEach { slog($0) }
                guard case .insert(let text, let deleteCount) = plan.action else { return }
                let showingMark = plan.markShown
                let readDetail = fieldRead?.detail ?? (pendingFieldRead == nil ? "notRead" : "timeout")
                // Logged once per dictation, after insertion, with per-stage
                // timings (BEA-663, F8). Numbers only — never field text.
                let logLine = "source=\(context.source.rawValue) provider=\(provider) app=\(releaseBundleID ?? "?") ax=\(readDetail) sameApp=\(frontmostPID == releasePID)\(plan.crossLog)"
                var lineTimings = stageTimings
                guard !text.isEmpty else {
                    TextHandlingLog.record("\(logLine) \(lineTimings.logFields)")
                    return
                }
                // Where the insertion ends inside a cursorless value, so the
                // next anchored lookup can tell repeated phrases apart.
                var position: ValuePosition?
                if context.source == .anchoredValue, let before = context.before,
                   let value = fieldRead?.value {
                    position = ValuePosition.afterInsertion(before: before, value: value, typed: text,
                                                            deletedBackward: deleteCount)
                }
                // Unknown context (source none): what preceded this insertion
                // is not known, so the remembered tail starts fresh instead of
                // gluing onto a tail the user may have deleted (BEA-677).
                let result = self.executor.insert(
                    text, deleteBackward: deleteCount, frontmostPID: frontmostPID,
                    secureInput: secureInputActive, copyToClipboard: self.copyToClipboard,
                    position: position, continuesTail: context.source != .none)
                if deleteCount > 0, frontmostPID != nil { slog("handsfree: retracted shown mark") }
                lineTimings.insert = result.insertDuration
                TextHandlingLog.record("\(logLine) \(lineTimings.logFields)")
                if showingMark && result.typed { self.hfJoiner.markShown() }
                if result.recorded, !isHandsFree, let frontmostPID,
                   let bounds = CrossDictationJoin.speechBounds(samples) {
                    let record = CrossDictationJoin.Previous(typed: text, pid: frontmostPID, fieldID: nil,
                                                             endedAt: Date(), position: position)
                    self.xPrev = (record, samples, bounds.last)
                } else {
                    self.xPrev = nil
                }
                if let toast = result.toast { self.toast.show(toast) }
            }
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
        hfJoiner = HeldMarkJoiner()
        hfPrevChunk = nil
        overlay.setHandsFree(true)
        slog("handsfree: latched")
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
        slog("handsfree: chunk \(chunk.count) samples")
        let generation = hfGate.token
        let pid = hfPID, bundleID = hfBundleID
        // Chunks are transcribed and typed strictly in order, in the same
        // queue as push-to-talk (BEA-665).
        insertionQueue.enqueue(isCurrent: { [weak self] in self?.hfGate.isCurrent(generation) ?? false }) {
            [weak self] in
            await self?.transcribeAndInsert(chunk, releasePID: pid, releaseBundleID: bundleID,
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
            let generation = hfGate.token
            let pid = hfPID
            insertionQueue.enqueue(isCurrent: { [weak self] in self?.hfGate.isCurrent(generation) ?? false }) {
                [weak self] in
                guard let self else { return }
                self.hfPrevChunk = nil
                self.executor.typeHeldMark(self.hfJoiner.stop(), sessionPID: pid)
            }
        } else {
            hfSession.discard(recorder)
            overlay.hide()
            hfGate.cancel() // drop chunks not yet typed, incl. one mid-transcription
            hfJoiner.discard() // and the held mark with them
            hfPrevChunk = nil
        }
        slog("handsfree: ended insert=\(insert) reason=\(String(describing: reason)) samples=\(hfSession.total)")
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
