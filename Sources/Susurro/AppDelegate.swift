import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SusurroCore
import UserNotifications

func slog(_ msg: String) {
    NSLog("[susurro] %@", msg)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var recordItem: NSMenuItem!
    private var hotkeyItem: NSMenuItem!

    // Production capture: AVAudioEngine. Alternatives evaluated and documented in
    // PLAN.md ("mic-mode pill"): HALAudioRecorder (raw CoreAudio — still pills),
    // SCKAudioRecorder (ScreenCaptureKit — no mic pill, but screen-recording pill,
    // Screen Recording permission, and 75–160 ms capture-start dead air).
    private let recorder = AudioRecorder()
    private let overlay = OverlayController()
    private let postProcessor = PostProcessor()
    private let models = ModelManager()
    private let toast = ToastPanel()
    private let helpWindow = HelpWindowController()
    private var modelMenu: NSMenu!
    private var cleanupItem: NSMenuItem!

    private var cleaner: (any TextCleaning)?
    private var cleanupEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "llmCleanupEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "llmCleanupEnabled") }
    }

    private var copyToClipboard: Bool {
        get { UserDefaults.standard.bool(forKey: "copyToClipboard") } // default off
        set { UserDefaults.standard.set(newValue, forKey: "copyToClipboard") }
    }
    private var smartSpacingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "smartSpacingEnabled") } // default off
        set { UserDefaults.standard.set(newValue, forKey: "smartSpacingEnabled") }
    }
    // Self-tracking, not an Accessibility read — see SMART_SPACING_PLAN.md.
    private var dictationMemory = DictationMemory()
    private let hotkey = HotkeyMonitor()
    private var engine: WhisperEngine?
    private var axPollTimer: Timer?

    private var sigSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform.circle",
                accessibilityDescription: "Susurro"
            )
        }

        let menu = NSMenu()
        let title = NSMenuItem(title: "Susurro — your amanuensis", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        recordItem = NSMenuItem(
            title: "Loading model…",
            action: #selector(toggleTestRecording),
            keyEquivalent: "r"
        )
        recordItem.target = self
        recordItem.isEnabled = false
        menu.addItem(recordItem)

        hotkeyItem = NSMenuItem(title: "Hotkey: checking permission…", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        let rulesItem = NSMenuItem(
            title: "Edit Rules…",
            action: #selector(openRules),
            keyEquivalent: ""
        )
        rulesItem.target = self
        menu.addItem(rulesItem)

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelMenu = NSMenu(title: "Model")
        modelItem.submenu = modelMenu
        modelMenu.delegate = self // refresh state every time the submenu opens
        menu.addItem(modelItem)
        rebuildModelMenu()

        let keyItem = NSMenuItem(title: "Push-to-Talk Key", action: nil, keyEquivalent: "")
        let keyMenu = NSMenu(title: "Push-to-Talk Key")
        for choice in PTTKey.all {
            let item = NSMenuItem(title: choice.title, action: #selector(pttKeyAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice == hotkey.key ? .on : .off
            keyMenu.addItem(item)
        }
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)

        cleanupItem = NSMenuItem(title: "AI Cleanup", action: #selector(cleanupAction), keyEquivalent: "")
        cleanupItem.target = self
        menu.addItem(cleanupItem)
        refreshCleanupItem()
        if #available(macOS 26.0, *) {
            let cleaner = TranscriptCleaner()
            self.cleaner = cleaner
            if cleanupEnabled {
                Task.detached { cleaner.prewarm() }
            }
        }

        let clipboardItem = NSMenuItem(
            title: "Copy Transcript to Clipboard",
            action: #selector(toggleClipboard(_:)),
            keyEquivalent: ""
        )
        clipboardItem.target = self
        clipboardItem.state = copyToClipboard ? .on : .off
        menu.addItem(clipboardItem)

        let smartSpacingItem = NSMenuItem(
            title: "Smart Spacing",
            action: #selector(toggleSmartSpacing(_:)),
            keyEquivalent: ""
        )
        smartSpacingItem.target = self
        smartSpacingItem.state = smartSpacingEnabled ? .on : .off
        menu.addItem(smartSpacingItem)

        let loginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        models.onProgress = { [weak self] _, _ in self?.rebuildModelMenu() }

        menu.addItem(.separator())

        let helpItem = NSMenuItem(title: "Help…", action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem(
            title: "Quit Susurro",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        menu.autoenablesItems = false
        menu.delegate = self // refresh AI-cleanup availability when menu opens
        statusItem.menu = menu

        setUpHotkey()

        // Request mic permission up front, decoupled from the first recording,
        // so the permission dialog can't interrupt an in-flight engine start.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            slog("mic permission granted=\(granted)")
            if !granted {
                Task { @MainActor [weak self] in
                    self?.recordItem.title = "Mic access denied — click to open Settings"
                    self?.recordItem.action = #selector(AppDelegate.openMicSettings)
                    self?.recordItem.isEnabled = true
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
                _ = self.recorder.stop()
                self.overlay.hide()
                self.toast.show("Recording interrupted — microphone changed")
                slog("recording interrupted by audio configuration change")
            }
        }

        loadEngine()

        // Debug/testing hook: `kill -USR1 <pid>` toggles recording,
        // enabling scripted experiments without a human at the hotkey.
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in
            self?.toggleTestRecording()
        }
        src.resume()
        sigSource = src
    }

    // MARK: - Models

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        MainActor.assumeIsolated {
            if menuID == ObjectIdentifier(modelMenu) {
                rebuildModelMenu()
            } else {
                refreshCleanupItem()
            }
        }
    }

    private func rebuildModelMenu() {
        modelMenu.removeAllItems()
        for model in ModelManager.catalog {
            let item = NSMenuItem(title: "", action: #selector(modelMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id

            if let progress = models.downloadProgress[model.id] {
                item.title = "\(model.id) — downloading \(Int(progress * 100))%"
                item.isEnabled = false
            } else if models.isDownloaded(model) {
                let active = model.id == models.activeModelID
                item.title = "\(model.id) (\(model.approxMB) MB) — \(model.note)"
                item.state = active ? .on : .off
            } else {
                item.title = "\(model.id) (\(model.approxMB) MB) — download"
            }
            modelMenu.addItem(item)
        }
        modelMenu.autoenablesItems = false
    }

    @objc private func modelMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let model = ModelManager.catalog.first(where: { $0.id == id }) else { return }

        if models.isDownloaded(model) {
            guard models.activeModelID != model.id else { return }
            models.activeModelID = model.id
            rebuildModelMenu()
            loadEngine() // hot-swap
        } else {
            guard !models.isDownloading(model) else {
                toast.show("\(model.id) is already downloading")
                return
            }
            // Clicking a model = "I want to use it": instant toast acknowledgment,
            // download, then auto-switch + notification (attention may be elsewhere).
            // Honest about current state: activeModelID has a default value even
            // when no model file exists at all.
            if models.activeModelPath() != nil {
                toast.show("⬇ Downloading \(model.id) — still on \(models.activeModelID) until it's ready")
            } else {
                toast.show("⬇ Downloading \(model.id) — no model active yet; dictation starts when it's ready")
            }
            Task { [weak self] in
                do {
                    try await self?.models.download(model)
                    guard let self else { return }
                    self.models.activeModelID = model.id
                    self.rebuildModelMenu()
                    self.loadEngine()
                    self.notify("Model ready",
                                "\(model.id) downloaded — Susurro is now using it.")
                } catch {
                    slog("model download failed: \(error)")
                    self?.notify("Model download failed",
                                 "\(model.id): \(error.localizedDescription)")
                    self?.rebuildModelMenu()
                }
            }
            rebuildModelMenu()
        }
    }

    private func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            ))
        }
    }

    /// Fresh install: no model anywhere — fetch the default automatically rather
    /// than leaving the app silently inert.
    private func autoDownloadDefaultModel() {
        guard let small = ModelManager.catalog.first(where: { $0.id == "small.en" }),
              !models.isDownloading(small) else { return }
        toast.show("⬇ First run: downloading the small.en model (466 MB) — dictation will be ready shortly")
        Task { [weak self] in
            do {
                try await self?.models.download(small)
                guard let self else { return }
                // Don't stomp a model the user explicitly chose in the meantime
                if self.models.activeModelPath() == nil || self.engine == nil {
                    self.models.activeModelID = small.id
                    self.loadEngine()
                    self.notify("Susurro is ready",
                                "small.en downloaded — hold your push-to-talk key to dictate.")
                }
                self.rebuildModelMenu()
            } catch {
                slog("auto-download failed: \(error)")
                self?.recordItem.title = "Model download failed — retry from the Model menu"
                self?.notify("Model download failed",
                             "Open the Model menu to retry. \(error.localizedDescription)")
                self?.rebuildModelMenu()
            }
        }
    }

    private func loadEngine() {
        guard let path = models.activeModelPath() else {
            recordItem.title = "Downloading model…"
            recordItem.isEnabled = false
            autoDownloadDefaultModel()
            return
        }
        engine = nil
        recordItem.title = "Loading model…"
        recordItem.isEnabled = false
        slog("loading model: \(path)")
        Task.detached(priority: .userInitiated) {
            do {
                let start = Date()
                let engine = try WhisperEngine(modelPath: path)
                slog(String(format: "model loaded in %.1fs", -start.timeIntervalSinceNow))
                await MainActor.run { [weak self] in
                    self?.engine = engine
                    self?.recordItem.title = "Start Test Recording"
                    self?.recordItem.isEnabled = true
                }
            } catch {
                slog("model load FAILED: \(error)")
                await MainActor.run { [weak self] in
                    self?.recordItem.title = "Model load failed"
                }
            }
        }
    }

    @objc private func openRules() {
        NSWorkspace.shared.open(postProcessor.userRulesURL)
    }

    @objc private func showHelp() {
        helpWindow.show()
    }

    // MARK: - AI cleanup

    private func refreshCleanupItem() {
        guard #available(macOS 26.0, *) else {
            cleanupItem.title = "AI Cleanup — requires macOS 26"
            cleanupItem.isEnabled = false
            return
        }
        switch TranscriptCleaner.availability() {
        case .available:
            cleanupItem.title = "AI Cleanup"
            cleanupItem.isEnabled = true
            cleanupItem.state = cleanupEnabled ? .on : .off
        case .appleIntelligenceNotEnabled:
            cleanupItem.title = "AI Cleanup — Enable Apple Intelligence…"
            cleanupItem.isEnabled = true
            cleanupItem.state = .off
        case .modelNotReady:
            cleanupItem.title = "AI Cleanup — Apple Intelligence model downloading…"
            cleanupItem.isEnabled = false
            cleanupItem.state = .off
        case .notSupported:
            cleanupItem.title = "AI Cleanup — not supported on this Mac"
            cleanupItem.isEnabled = false
            cleanupItem.state = .off
        }
    }

    @objc private func cleanupAction() {
        guard #available(macOS 26.0, *) else { return }
        switch TranscriptCleaner.availability() {
        case .available:
            cleanupEnabled.toggle()
            refreshCleanupItem()
            if cleanupEnabled {
                toast.show("AI Cleanup on — transcripts get a grammar pass (~1s)")
                if let cleaner {
                    Task.detached { cleaner.prewarm() }
                }
            } else {
                toast.show("AI Cleanup off")
            }
        case .appleIntelligenceNotEnabled:
            showAppleIntelligenceInstructions()
        default:
            break
        }
    }

    private func showAppleIntelligenceInstructions() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AI Cleanup needs Apple Intelligence"
        alert.informativeText = """
        Susurro's AI Cleanup runs entirely on your Mac using Apple Intelligence, \
        which is currently turned off.

        To enable it:
        1. Open System Settings → Apple Intelligence & Siri
        2. Turn on Apple Intelligence
        3. Wait for the model download to complete (a few minutes)

        Then click "AI Cleanup" in Susurro's menu again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            let pane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
            if let pane, NSWorkspace.shared.urlForApplication(toOpen: pane) != nil {
                NSWorkspace.shared.open(pane)
            } else if let settings = URL(string: "x-apple.systempreferences:") {
                NSWorkspace.shared.open(settings)
            }
        }
    }

    @objc private func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleClipboard(_ sender: NSMenuItem) {
        copyToClipboard.toggle()
        sender.state = copyToClipboard ? .on : .off
        toast.show(copyToClipboard
            ? "Transcripts will also be copied to the clipboard"
            : "Clipboard untouched (except in password fields, where typing is blocked)")
    }

    @objc private func toggleSmartSpacing(_ sender: NSMenuItem) {
        smartSpacingEnabled.toggle()
        sender.state = smartSpacingEnabled ? .on : .off
        if !smartSpacingEnabled {
            dictationMemory.clear()
        }
        toast.show(smartSpacingEnabled
            ? "Smart Spacing on — dictating again right after a . ! or ? adds a space"
            : "Smart Spacing off")
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
                toast.show("Susurro will no longer start at login")
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
                toast.show("Susurro will start at login")
            }
        } catch {
            slog("login item toggle failed: \(error)")
            toast.show("Couldn't change login item: \(error.localizedDescription)")
        }
    }

    @objc private func pttKeyAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let choice = PTTKey.all.first(where: { $0.id == id }) else { return }
        hotkey.key = choice
        choice.save()
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
        hotkeyItem.title = "Hotkey: hold \(choice.title) to dictate"
        toast.show("Push-to-talk key is now \(choice.title)")
    }

    // MARK: - Hotkey (push-to-talk)

    private func setUpHotkey() {
        hotkey.onPress = { [weak self] in self?.pttPressed() }
        hotkey.onRelease = { [weak self] in self?.pttReleased() }

        if HotkeyMonitor.ensureAccessibility(prompt: true), hotkey.start() {
            hotkeyGranted()
        } else {
            slog("accessibility not granted yet — polling")
            hotkeyItem.title = "Hotkey: grant Accessibility in System Settings"
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
        hotkeyItem.title = "Hotkey: hold \(hotkey.key.title) to dictate"
    }

    private func pttPressed() {
        guard engine != nil, !recorder.isRecording else { return }
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
        guard let engine else { return }
        let postProcessor = postProcessor
        let cleaner = cleanupEnabled ? self.cleaner : nil
        Task.detached(priority: .userInitiated) {
            let raw = TranscriptFilter.stripHallucinations(
                (try? engine.transcribe(samples: samples)) ?? ""
            )
            var text = raw.isEmpty ? "" : postProcessor.process(raw)
            if let cleaner, !text.isEmpty {
                text = await cleaner.clean(text) ?? text
            }
            slog("ptt: transcript: \(raw) -> \(text)")
            await MainActor.run { [weak self] in
                guard let self, !text.isEmpty else { return }
                // Secure input (password fields) silently blocks synthetic typing —
                // in that case copy regardless of the setting so the words aren't lost.
                let secureInputActive = IsSecureEventInputEnabled()
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                // Smart Spacing: self-tracked, not an Accessibility read (see
                // SMART_SPACING_PLAN.md) — only fires if Susurro itself typed
                // into this same frontmost app last time.
                if !secureInputActive, self.smartSpacingEnabled, let frontmostPID,
                   SpacingRule.needsLeadingSpace(
                       beforeCursor: self.dictationMemory.tailIfStillFocused(pid: frontmostPID)
                   ) {
                    text = " " + text
                }
                TextInjector.type(text)
                if !secureInputActive, let frontmostPID {
                    self.dictationMemory.recordTyped(text, intoPID: frontmostPID)
                } else {
                    // Nothing was actually typed (secure input blocked it) or we
                    // couldn't identify the frontmost app — don't let a stale
                    // tail leak into whatever's focused next.
                    self.dictationMemory.clear()
                }
                if self.copyToClipboard || secureInputActive {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    if secureInputActive && !self.copyToClipboard {
                        self.toast.show("Typing blocked by a secure field — transcript copied to clipboard")
                    }
                }
            }
        }
    }

    // Menu bar icon stays static: the overlay waveform (and the system mic pill)
    // are the recording indicators — a third one was visual noise.

    // MARK: - Test recording via menu (kept until M1.6)

    @objc private func toggleTestRecording() {
        if recorder.isRecording {
            let samples = recorder.stop()
            recordItem.title = "Transcribing…"
            recordItem.isEnabled = false
            guard let engine else { return }
            Task.detached(priority: .userInitiated) { [weak self] in
                let text = (try? engine.transcribe(samples: samples)) ?? "(transcription failed)"
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    self?.recordItem.title = "Start Test Recording"
                    self?.recordItem.isEnabled = true
                }
            }
        } else {
            do {
                try recorder.start()
                recordItem.title = "Stop → Transcribe → Clipboard"
                slog("recording started")
            } catch {
                slog("recorder.start FAILED: \(error)")
                recordItem.title = "Mic failed — click to retry"
            }
        }
    }
}
