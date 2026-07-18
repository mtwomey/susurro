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
    // docs/PLAN.md ("mic-mode pill"): HALAudioRecorder (raw CoreAudio — still pills),
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
    // Self-tracking, not an Accessibility read — see docs/SMART_SPACING_PLAN.md.
    private var dictationMemory = DictationMemory()
    private let hotkey = HotkeyMonitor()
    private var engine: WhisperEngine?
    private var axPollTimer: Timer?

    // Set once if the mic-permission callback reports denial. Sticky for the
    // rest of the run (TCC changes need a relaunch to take effect anyway) so
    // that transient model load/download status updates — which share the
    // same status menu item — can never silently clobber this more
    // important, persistent warning. See setStatus(_:enabled:action:).
    private var micAccessDenied = false

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

        // Hotkey status: a parenthetical subtitle right under the app name —
        // informational only (isEnabled stays false), not a command among
        // the actionable items below the divider. See setHotkeyStatus(_:).
        hotkeyItem = NSMenuItem(title: "(checking permission…)", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        menu.addItem(.separator())

        // Status line: shows model load/download progress and permission
        // problems. Removed from the menu once the engine is ready — see
        // setStatus(_:enabled:action:) / clearStatus().
        recordItem = NSMenuItem(title: "Loading model…", action: nil, keyEquivalent: "")
        recordItem.target = self
        recordItem.isEnabled = false
        menu.addItem(recordItem)

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelMenu = NSMenu(title: "Model")
        modelItem.submenu = modelMenu
        modelMenu.delegate = self // refresh state every time the submenu opens
        menu.addItem(modelItem)
        rebuildModelMenu()
        models.onProgress = { [weak self] _, _ in self?.rebuildModelMenu() }

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

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let smartSpacingItem = NSMenuItem(
            title: "Smart Spacing",
            action: #selector(toggleSmartSpacing(_:)),
            keyEquivalent: ""
        )
        smartSpacingItem.target = self
        smartSpacingItem.state = smartSpacingEnabled ? .on : .off
        menu.addItem(smartSpacingItem)

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

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About Susurro", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let helpItem = NSMenuItem(title: "Help…", action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        let rulesItem = NSMenuItem(
            title: "Edit Rules…",
            action: #selector(openRules),
            keyEquivalent: ""
        )
        rulesItem.target = self
        menu.addItem(rulesItem)

        let gitHubItem = NSMenuItem(title: "GitHub", action: #selector(openGitHub), keyEquivalent: "")
        gitHubItem.target = self
        menu.addItem(gitHubItem)

        let quitItem = NSMenuItem(title: "Quit Susurro", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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
                    guard let self else { return }
                    self.micAccessDenied = true
                    self.setStatus(
                        "Mic access denied — click to open Settings",
                        enabled: true,
                        action: #selector(AppDelegate.openMicSettings),
                        overridesMicWarning: true
                    )
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
                self?.setStatus("Model download failed — retry from the Model menu")
                self?.notify("Model download failed",
                             "Open the Model menu to retry. \(error.localizedDescription)")
                self?.rebuildModelMenu()
            }
        }
    }

    /// Shows (or updates) the status menu item — inserted back into the menu
    /// if it isn't there, since `loadEngine()` can run again later (model
    /// hot-swap, retry after failure) after `clearStatus()` removed it.
    ///
    /// `recordItem` is shared between two unrelated concerns: transient
    /// model load/download status, and the persistent mic-access-denied
    /// warning. Without `overridesMicWarning`, a fast model load finishing
    /// right after mic access was denied would silently clobber that
    /// warning with "Loading model…"/clear it entirely — leaving no menu
    /// indication of why dictation still doesn't work. Only the
    /// mic-permission callback passes `overridesMicWarning: true`.
    private func setStatus(
        _ title: String,
        enabled: Bool = false,
        action: Selector? = nil,
        overridesMicWarning: Bool = false
    ) {
        guard overridesMicWarning || !micAccessDenied else { return }
        recordItem.title = title
        recordItem.isEnabled = enabled
        recordItem.action = action
        if let menu = statusItem.menu, !menu.items.contains(recordItem) {
            // Anchored off hotkeyItem's live index rather than a hardcoded
            // literal, so this can't silently drift if an item is ever
            // inserted/removed above this point in the menu construction.
            // Layout is: title, hotkeyItem, separator, [recordItem here].
            let anchor = menu.items.firstIndex(of: hotkeyItem).map { $0 + 2 } ?? menu.items.count
            menu.insertItem(recordItem, at: min(anchor, menu.items.count))
        }
    }

    /// Sets the hotkey status subtitle (parenthetical, directly under the
    /// app name — see menu construction above).
    private func setHotkeyStatus(_ text: String) {
        hotkeyItem.title = "(\(text))"
    }

    /// Removes the status item once there's nothing to report — dictation is
    /// ready and available via the push-to-talk hotkey. Never clears a
    /// mic-access-denied warning (see setStatus) — that's sticky for the
    /// rest of the run.
    private func clearStatus() {
        guard !micAccessDenied else { return }
        if let menu = statusItem.menu, menu.items.contains(recordItem) {
            menu.removeItem(recordItem)
        }
    }

    private func loadEngine() {
        guard let path = models.activeModelPath() else {
            setStatus("Downloading model…")
            autoDownloadDefaultModel()
            return
        }
        engine = nil
        setStatus("Loading model…")
        slog("loading model: \(path)")
        Task.detached(priority: .userInitiated) {
            do {
                let start = Date()
                let engine = try WhisperEngine(modelPath: path)
                slog(String(format: "model loaded in %.1fs", -start.timeIntervalSinceNow))
                await MainActor.run { [weak self] in
                    self?.engine = engine
                    self?.clearStatus()
                }
            } catch {
                slog("model load FAILED: \(error)")
                await MainActor.run { [weak self] in
                    self?.setStatus("Model load failed")
                }
            }
        }
    }

    @objc private func openRules() {
        NSWorkspace.shared.open(postProcessor.userRulesURL)
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/mtwomey/susurro")!)
    }

    // Routed through our own selector rather than #selector(NSApplication.terminate(_:))
    // directly: AppKit auto-attaches a small quit glyph to menu items whose action is
    // exactly `terminate:` in status-bar menus, which was the only item with an icon
    // and threw off the menu's left alignment. This is functionally identical —
    // NSApp.terminate(nil) is what terminate(_:) calls anyway — but avoids the glyph.
    @objc private func quit() {
        NSApp.terminate(nil)
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
            ? "Smart Spacing on — dictating again adds a space, unless one's already there"
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
        setHotkeyStatus("hold \(choice.title) to dictate")
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
            setHotkeyStatus("grant Accessibility in System Settings")
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
        setHotkeyStatus("hold \(hotkey.key.title) to dictate")
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
                // docs/SMART_SPACING_PLAN.md) — only fires if Susurro itself typed
                // into this same frontmost app last time.
                if !secureInputActive, self.smartSpacingEnabled, let frontmostPID,
                   SpacingRule.needsLeadingSpace(
                       beforeCursor: self.dictationMemory.tailIfStillFocused(pid: frontmostPID)
                   ) {
                    text = " " + text
                }
                let typed = TextInjector.type(text)
                if !secureInputActive, typed, let frontmostPID {
                    self.dictationMemory.recordTyped(text, intoPID: frontmostPID)
                } else {
                    // Nothing was actually typed (secure input blocked it, a
                    // keystroke event failed to post, or we couldn't identify
                    // the frontmost app) — don't let a stale tail leak into
                    // whatever's focused next.
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

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Susurro"
        let versionLine = build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
        alert.informativeText = "\(versionLine)\nMatthew Twomey"
        // NSAlert's default icon falls back to a generic placeholder for
        // .accessory-policy (menu-bar-only, no Dock tile) apps like this one
        // — NSApp.applicationIconImage doesn't reliably resolve without a
        // Dock presence. Load the bundled icon directly instead.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            alert.icon = icon
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
