import AppKit
import Carbon
import SusurroCore

/// Transcribe one dictation (push-to-talk release, hands-free chunk, dev
/// feed) and insert it — the F1 hotspot, moved out of AppDelegate (R4) with
/// the join state it owns. Runs inside InsertionQueue jobs.
@MainActor
final class DictationController {
    // Cancel (Esc) moves the gate on: queued chunks are dropped, and a chunk
    // already mid-transcription is dropped at insert time (BEA-663, F2).
    var gate = SessionGate()
    // Hands-free joins (BEA-657): each chunk's final end mark is held back and
    // decided from a joint transcript across the pause when the next chunk lands.
    var joiner = HeldMarkJoiner()
    var prevChunk: HFChunk?       // audio of the chunk whose mark is held
    /// Cross-dictation joins (BEA-677): the previous push-to-talk insertion
    /// and its audio, kept so the next dictation can decide its full stop.
    private var xPrev: (record: CrossDictationJoin.Previous, samples: [Float], lastSpeech: Int)?
    /// Latch (BEA-691): a latched chunk could not be delivered. The app
    /// copies `text`, shows the pill, and ends latch (stays hands-free).
    /// The report carries everything undelivered so far (clipboard text) and
    /// whether this failure is the one that ended the latch (pill once).
    var onLatchFailure: ((_ report: LatchSession.Report, _ pin: LatchPin) -> Void)?

    private enum LatchPlan {
        case insert(text: String, before: String, record: DictationRecord)
        case contextFailed(text: String, failure: LatchFailure, record: DictationRecord)
    }

    private let engine: () -> EngineLease?
    private let cleaner: () -> (any TextCleaning)?
    private let postProcessor: PostProcessor
    private let settings: Settings
    private let executor: InsertExecutor
    private let toast: ToastPanel

    init(engine: @escaping () -> EngineLease?, cleaner: @escaping () -> (any TextCleaning)?,
         postProcessor: PostProcessor, settings: Settings, executor: InsertExecutor, toast: ToastPanel) {
        self.engine = engine
        self.cleaner = cleaner
        self.postProcessor = postProcessor
        self.settings = settings
        self.executor = executor
        self.toast = toast
    }

    /// Transcribe `samples` and insert the result into the focused field.
    /// `expectedPID` (hands-free chunks): if another app is frontmost by the
    /// time the text is ready, it goes to the clipboard instead of being typed
    /// into the wrong app. nil = today's push-to-talk behaviour, unchanged.
    @discardableResult
    func transcribeAndInsert(_ samples: [Float], releasePID: pid_t?, releaseBundleID: String?,
                                     expectedPID: pid_t?, hfChunk: HFChunk? = nil,
                                     hfToken: Int? = nil,
                                     trigger: DictationRecord.Trigger? = nil,
                                     latch: LatchSession? = nil) -> Task<Void, Never>? {
        // The lease pins the engine this dictation started with across a model
        // switch (R8): it finishes on the old engine, which is freed once the
        // last such job ends.
        guard let lease = engine() else { return nil }
        let engine = lease.engine
        // One structured record per dictation (R7, F14): carries no text.
        let baseRecord = DictationRecord(trigger: trigger ?? (hfChunk != nil ? .handsFree : .pushToTalk),
                                         engine: engine.kind, outcome: .empty)
        let postProcessor = postProcessor
        // Transcript side of the dictation (BEA-664, R2): the same pipeline
        // susurro-cli runs, so the eval harness exercises this code.
        let pipeline = DictationPipeline(engine: engine, postProcessor: postProcessor,
                                         cleaner: settings.llmCleanupEnabled ? self.cleaner() : nil)
        // Text handling (BEA-648): read the focused field through
        // Accessibility while the engine transcribes; capped at 250 ms.
        // Smart Spacing is the stage's master toggle — off means no read and
        // the old context-free behaviour (sentence case only).
        var fieldTask: Task<(FieldSnapshot?, Duration), Never>?
        // Latched chunks take their context from the pinned target, never
        // from the frontmost field.
        if latch == nil, settings.smartSpacingEnabled, !IsSecureEventInputEnabled(), let pid = releasePID {
            fieldTask = Task.detached(priority: .userInitiated) {
                let clock = ContinuousClock(), start = clock.now
                let snapshot = await FocusedFieldReader.read(pid: pid, bundleID: releaseBundleID)
                return (snapshot, clock.now - start)
            }
        }
        let pendingFieldRead = fieldTask
        return Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(lease) {} }
            let clock = ContinuousClock()
            var timings = StageTimings()
            let transcript: String
            var transcriptionFailed = false
            let transcribeStart = clock.now
            do {
                transcript = try engine.transcribe(samples: samples)
            } catch {
                transcriptionFailed = true
                Log.engine.failure("transcription failed: \(error)")
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
            Log.transcript(raw: raw, cleaned: cleaned)
            // Latch: context at the pin (off the main actor; socket/CLI trip).
            let latchContext = await latch?.context()
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
                    guard let self, self.gate.isCurrent(hfToken) else { return nil }
                    let previous = self.prevChunk
                    let plan = self.joiner.accept(cleaned, pid: expectedPID)
                    self.prevChunk = hfChunk
                    return (plan, previous)
                }
                if let step {
                    var jointTime: Duration?
                    hfStep = try? pipeline.handsFreeStep(step.0, previous: step.1, current: hfChunk,
                                                         jointSeconds: &jointTime, failedJointAsEmpty: true)
                    if let jointTime { timings.joinTranscribe = jointTime }
                    if case .joined(let held, let decision, _, _)? = hfStep {
                        Log.handsfree.event("join decision=\(decision) held=\(held.mark)")
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
            var started = baseRecord
            started.timings = timings
            started.transcriptionFailed = transcriptionFailed
            started.app = releaseBundleID
            let recordBase = started
            if let latch {
                // Latch (BEA-691): plan on the main actor, insert through the
                // bridge off it (socket/CLI round trip), report on it again.
                // Still one queue job, so chunks land strictly in order.
                let planned = await MainActor.run { [weak self] () -> LatchPlan? in
                    guard let self else { return nil }
                    var record = recordBase
                    guard self.gate.isCurrent(hfToken) else {
                        record.outcome = .dropped
                        record.emit()
                        return nil
                    }
                    guard !processed.isEmpty || joinText != nil else {
                        record.outcome = .empty
                        record.emit()
                        return nil
                    }
                    return self.planLatched(processed: processed, join: join, latch: latch,
                                            contextReply: latchContext ?? .unavailable,
                                            engine: engine.kind, autoCapitalize: autoCapitalize,
                                            startedAt: startedAt, record: record)
                }
                switch planned {
                case nil:
                    return
                case .contextFailed(let text, let failure, let record)?:
                    let report = await latch.fail(text, because: failure)
                    await MainActor.run { [weak self] in
                        self?.completeLatched(report, text: text, pin: latch.pin, record: record)
                    }
                case .insert(let text, let before, let record)?:
                    let report = await latch.deliver(text, contextBefore: before)
                    await MainActor.run { [weak self] in
                        self?.completeLatched(report, text: text, pin: latch.pin, record: record)
                    }
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                var record = recordBase
                guard self.gate.isCurrent(hfToken) else {
                    Log.handsfree.event("chunk dropped — session cancelled during transcription")
                    record.outcome = .dropped
                    record.emit()
                    return
                }
                guard !processed.isEmpty || joinText != nil else {
                    record.outcome = .empty
                    record.emit()
                    return
                }
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
                    self.joiner.discard()
                    self.toast.show(message)
                    Log.handsfree.event("chunk after app switch -> clipboard")
                    record.outcome = .clipboardAppSwitch
                    record.emit()
                    return
                }
                // Pre-insert text-handling stage (docs/TEXT_HANDLING_FINDINGS.md):
                // Accessibility read of the focused field, self-tracked memory as
                // the fallback, unknown = empty field. The AX read only counts if
                // the same app is still frontmost. Field text is never logged.
                let context: InsertContext
                var provider = "off"
                if self.settings.smartSpacingEnabled {
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
                let stage = TextHandlingStage.standard(smartSpacing: self.settings.smartSpacingEnabled,
                                                       autoCapitalize: autoCapitalize)
                // The insert decisions are pure (SusurroCore InsertPlan,
                // BEA-664); this block only gathers facts and carries them out.
                let plan = InsertPlan.make(
                    processed: processed, join: join, isHandsFree: isHandsFree,
                    expectedPID: expectedPID, frontmostPID: frontmostPID,
                    context: context, stage: stage, secureInput: secureInputActive,
                    heldMark: self.joiner.held?.mark,
                    cross: self.xPrev.map { ($0.record, crossDecision) },
                    startedAt: startedAt, fieldValue: fieldRead?.value)
                plan.notes.forEach { Log.textHandling.event($0) }
                guard case .insert(let text, let deleteCount) = plan.action else {
                    record.outcome = .notInserted
                    record.emit()
                    return
                }
                let showingMark = plan.markShown
                // Logged once per dictation, after insertion, with per-stage
                // timings (BEA-663, F8). Numbers only — never field text.
                record.source = context.source
                record.provider = provider
                record.ax = fieldRead?.detail ?? (pendingFieldRead == nil ? "notRead" : "timeout")
                record.sameApp = frontmostPID == releasePID
                record.cross = plan.crossLog
                guard !text.isEmpty else {
                    record.outcome = .nothingToType
                    record.emit()
                    TextHandlingLog.record(record)
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
                    secureInput: secureInputActive, copyToClipboard: self.settings.copyToClipboard,
                    position: position, continuesTail: context.source != .none)
                if deleteCount > 0, frontmostPID != nil { Log.handsfree.event("retracted shown mark") }
                record.timings.insert = result.insertDuration
                record.outcome = .inserted
                record.emit()
                TextHandlingLog.record(record)
                if showingMark && result.typed { self.joiner.markShown() }
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

    /// Latch delivery (BEA-691): plan the piece from the context at the pin,
    /// insert through the target's bridge, verify the read-back. Any failure:
    /// the text goes to the clipboard and latch ends — never another app.
    /// Shown-mark mode is off here (context source is not "readable"), so a
    /// held end mark is only ever appended, never retracted with Backspace.
    /// Returns (text to insert, context before, record), or nil when there
    /// is nothing to insert or the target already failed (handled here).
    private func planLatched(processed: String, join: InsertPlan.Join, latch: LatchSession,
                             contextReply: LatchBridgeReply, engine: EngineKind,
                             autoCapitalize: Bool, startedAt: Date,
                             record: DictationRecord) -> LatchPlan? {
        var record = record
        let fallback = InsertPlan.appSwitchClipboardText(processed: processed, join: join)
        if let failure = LatchDelivery.contextFailure(contextReply), case .failed(let why) = failure {
            return .contextFailed(text: fallback, failure: why, record: record)
        }
        guard case .value(let before) = contextReply else { return nil }
        let context = InsertContext(before: before, source: .selfTracked, bundleID: latch.pin.bundleID,
                                    engine: engine)
        let stage = TextHandlingStage.standard(smartSpacing: settings.smartSpacingEnabled,
                                               autoCapitalize: autoCapitalize)
        let plan = InsertPlan.make(processed: processed, join: join, isHandsFree: true,
                                   expectedPID: nil, frontmostPID: nil, context: context, stage: stage,
                                   secureInput: false, heldMark: joiner.held?.mark, cross: nil,
                                   startedAt: startedAt, fieldValue: nil)
        guard case .insert(let text, _) = plan.action, !text.isEmpty else {
            record.outcome = .nothingToType
            record.emit()
            return nil
        }
        return .insert(text: text, before: before, record: record)
    }

    private func completeLatched(_ report: LatchSession.Report, text: String, pin: LatchPin,
                                 record: DictationRecord) {
        var record = record
        if case .failed = report.outcome {
            joiner.discard()
            onLatchFailure?(report, pin)
            record.outcome = .clipboardAppSwitch
        } else {
            record.outcome = .inserted
            Log.handsfree.event("latch chunk delivered (\(text.count) chars)")
        }
        record.emit()
    }

    /// Latch stop: append the held end mark at the pin (never the frontmost app).
    func finishLatched(_ latch: LatchSession) async {
        prevChunk = nil
        guard let mark = joiner.stop() else { return }
        let report = await latch.deliver(String(mark))
        if case .failed = report.outcome { onLatchFailure?(report, latch.pin) }
    }
}
