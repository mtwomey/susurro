import AppKit
import Carbon
import SusurroCore

/// Developer-only hooks (BEA-677), moved out of AppDelegate (review R4). Both
/// are off unless `defaults write <bundle id> DevFeedHook -bool YES`.
@MainActor
final class DevHooks {
    /// What the context probe needs from the live app.
    struct ProbeInputs {
        var memory: RememberedInsertion?
        var engine: EngineKind?
        var smartSpacing: Bool
        var autoCapitalize: Bool
    }

    /// Queue `samples` as one push-to-talk dictation into (pid, bundleID).
    private let feed: ([Float], pid_t?, String?) -> Void
    private let probeInputs: (pid_t) -> ProbeInputs

    init(feed: @escaping ([Float], pid_t?, String?) -> Void,
         probeInputs: @escaping (pid_t) -> ProbeInputs) {
        self.feed = feed
        self.probeInputs = probeInputs
    }

    /// Dev hook (BEA-677): feed a WAV into the running app instead of the
    /// microphone, as if it were one push-to-talk dictation into the
    /// frontmost app. Off unless `defaults write <bundle id> DevFeedHook -bool YES`.
    ///   scripts/feed_wav.sh clip.wav   (posts com.susurro.dev.feedWAV, object = "<bundle id>|<path>")
    func install() {
        guard Settings().devFeedHook else { return }
        Log.dictation.event("feed-WAV hook enabled")
        installProbe()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.susurro.dev.feedWAV"), object: nil, queue: .main
        ) { [weak self] note in
            // object = "<expected frontmost bundle id>|<wav path>". The clip is
            // only typed when that app is frontmost: a dev run must never
            // type into whatever the user happens to be using.
            guard let payload = note.object as? String, let bar = payload.firstIndex(of: "|") else { return }
            let expected = String(payload[..<bar]), path = String(payload[payload.index(after: bar)...])
            MainActor.assumeIsolated {
                guard let self else { return }
                let app = NSWorkspace.shared.frontmostApplication
                guard !expected.isEmpty, app?.bundleIdentifier == expected else {
                    Log.dictation.event("feed WAV refused — frontmost app is not the expected target")
                    return
                }
                do {
                    let samples = try AudioFileLoader.loadSamples(url: URL(fileURLWithPath: path))
                    Log.dictation.event("feeding WAV (\(samples.count) samples)")
                    self.feed(samples, app?.processIdentifier, app?.bundleIdentifier)
                } catch {
                    Log.dictation.failure("feed WAV failed: \(error)")
                }
            }
        }
    }

    /// Dev context probe (BEA-677): run the real pre-insert pipeline
    /// (FocusedFieldReader + InsertContext.resolve + TextHandlingStage) on the
    /// frontmost app for a given transcript, WITHOUT typing anything. Same
    /// DevFeedHook switch. object = "<target bundle id>|end|<transcript>"; the
    /// result is written as JSON to ~/Library/Logs/Susurro/probe.json (dev
    /// only: contains the field tail, never written in normal use).
    private func installProbe() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.susurro.dev.probe"), object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = note.object as? String, let bar = payload.firstIndex(of: "|") else { return }
            // object = "<target bundle id>|<end|here>|<transcript>"
            let expected = String(payload[..<bar])
            var rest = payload[payload.index(after: bar)...]
            var caretToEnd = false
            if let bar2 = rest.firstIndex(of: "|") {
                caretToEnd = rest[..<bar2] == "end"
                rest = rest[rest.index(after: bar2)...]
            }
            // Optional "prev=<text Susurro typed last>|" segment: also report
            // the cross-dictation guard verdict against the live field.
            var prevTyped: String?
            if rest.hasPrefix("prev="), let bar3 = rest.firstIndex(of: "|") {
                prevTyped = String(rest[rest.index(rest.startIndex, offsetBy: 5)..<bar3])
                rest = rest[rest.index(after: bar3)...]
            }
            let transcript = String(rest)
            MainActor.assumeIsolated {
                guard let self else { return }
                // The target need not be frontmost: Accessibility reads each
                // app's own focused element, so the probe runs on a background
                // scratch window and never touches the app the user is in.
                let app = NSRunningApplication.runningApplications(withBundleIdentifier: expected).first
                var out: [String: Any] = ["frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?",
                                          "target": expected]
                let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Susurro")
                func write() {
                    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
                        try? data.write(to: logs.appendingPathComponent("probe.json"))
                    }
                }
                guard let app else { out["error"] = "target_not_running"; write(); return }
                if caretToEnd { Self.moveCaretToEnd(pid: app.processIdentifier) }
                let pid = app.processIdentifier
                let snapshot = FocusedFieldReader.readNow(pid: pid, bundleID: app.bundleIdentifier)
                let inputs = self.probeInputs(pid)
                let (context, provider) = InsertContext.resolve(
                    snapshot: snapshot, memory: inputs.memory,
                    pid: pid, bundleID: app.bundleIdentifier, engine: inputs.engine,
                    secureInput: IsSecureEventInputEnabled())
                let stage = TextHandlingStage.standard(smartSpacing: inputs.smartSpacing,
                                                       autoCapitalize: inputs.autoCapitalize)
                out["source"] = context.source.rawValue
                out["provider"] = provider
                out["detail"] = snapshot.detail
                out["beforeTail"] = context.before.map { String($0.suffix(40)) } ?? NSNull()
                out["afterHead"] = context.after.map { String($0.prefix(40)) } ?? NSNull()
                out["startsSentence"] = context.startsSentence
                out["output"] = stage.apply(transcript, context)
                if let prevTyped {
                    let readable = [.accessibility, .anchoredValue, .appBridge].contains(context.source) && context.before != nil
                    let now = Date()
                    let verdict = CrossDictationJoin.check(
                        previous: .init(typed: prevTyped, pid: pid, fieldID: nil, endedAt: now.addingTimeInterval(-3)),
                        current: .init(pid: pid, fieldID: nil, startedAt: now,
                                       before: readable ? context.before : nil, after: context.after))
                    switch verdict {
                    case .eligible: out["xjoin"] = "eligible"
                    case .ineligible(let r): out["xjoin"] = r.rawValue
                    }
                }
                write()
                Log.dictation.event("context probe written")
            }
        }
    }

    /// Dev only: put the caret at the end of the target app's focused text
    /// element (AX selected range), so probes start from a known position.
    private static func moveCaretToEnd(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return }
        let element = el as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return }
        var range = CFRange(location: (text as NSString).length, length: 0)
        if let axRange = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
    }
}
