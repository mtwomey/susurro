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
    private var latchItem: NSMenuItem!

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

    // Hands-free (BEA-651). The machine decides; the rest is plumbing.
    private var handsFree = HandsFreeMachine()
    private var segmenter = PauseSegmenter()
    private var hfBuffer: [Float] = []      // samples of the unfinished segment
    private var hfBufferStart = 0           // absolute index of hfBuffer[0]
    private var hfTotal = 0                 // samples drained this session
    private var hfLastSpeech: Int?
    private var hfTimer: Timer?
    private var hfPID: pid_t?
    private var hfBundleID: String?
    private var hfAppObserver: NSObjectProtocol?
    private var hfInsertChain: Task<Void, Never>?
    private var hfGeneration = 0            // bumped on cancel: queued chunks are dropped
    // Hands-free joins (BEA-657): each chunk's final end mark is held back and
    // decided from a joint transcript across the pause when the next chunk lands.
    private var hfJoiner = HeldMarkJoiner()
    private var hfPrevChunk: HFChunk?       // audio of the chunk whose mark is held
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var engine: (any TranscriptionEngine)?
    // Bumped on every loadEngine() call; a load that finishes after a newer
    // one started (fast menu switching) is discarded instead of winning.
    private var engineGeneration = 0
    /// Why there's no engine right now, for user-visible feedback. The menu
    /// status item alone is invisible unless the menu is open, and a cold
    /// Parakeet load (Core ML compile) takes ~20 s, so without this the app
    /// looked broken: push-to-talk silently did nothing.
    private enum EngineState { case loading, downloading, failed, ready }
    private var engineState: EngineState = .loading {
        didSet { updateStatusIcon() }
    }
    /// A load slower than this gets a "still loading" toast and a "ready" toast.
    private static let slowLoadThreshold: TimeInterval = 1.5
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

        // Hands-free latch key (BEA-651): never the push-to-talk key.
        latchItem = NSMenuItem(title: "Hands-Free Latch Key", action: nil, keyEquivalent: "")
        latchItem.submenu = NSMenu(title: "Hands-Free Latch Key")
        menu.addItem(latchItem)
        rebuildLatchMenu()

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
        // One menu, sectioned by engine (Parakeet is Apple Silicon only;
        // menuSections() omits it elsewhere). Picking any entry hot-swaps the
        // engine via loadEngine(). Keep HelpWindow's "Model" text in sync.
        for (index, section) in ModelManager.menuSections().enumerated() {
            if index > 0 { modelMenu.addItem(.separator()) }
            modelMenu.addItem(.sectionHeader(title: section.engine.menuSectionTitle))
            for model in section.models {
                modelMenu.addItem(modelMenuItem(for: model))
            }
        }
        modelMenu.autoenablesItems = false
    }

    /// Size and note are shown in every state so an undownloaded model can be
    /// judged before committing to the download.
    private func modelMenuItem(for model: CatalogModel) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(modelMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = model.id
        let label = "\(model.id) (\(model.approxMB) MB) — \(model.note)"
        if let progress = models.downloadProgress[model.id] {
            item.title = "\(label) — downloading \(Int(progress * 100))%"
            item.isEnabled = false
        } else if models.isDownloaded(model) {
            item.title = label
            item.state = model.id == models.activeModelID ? .on : .off
        } else {
            item.title = "\(label) — download"
        }
        return item
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
                self?.engineState = .failed
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
    /// Menu bar icon reflects engine readiness, so a loading app doesn't look
    /// identical to a ready one.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let (symbol, tip): (String, String) = switch engineState {
        case .ready: ("waveform.circle", "Susurro")
        case .loading: ("hourglass.circle", "Susurro — loading model…")
        case .downloading: ("arrow.down.circle", "Susurro — downloading model…")
        case .failed: ("exclamationmark.circle", "Susurro — model load failed")
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
    }

    private func clearStatus() {
        guard !micAccessDenied else { return }
        if let menu = statusItem.menu, menu.items.contains(recordItem) {
            menu.removeItem(recordItem)
        }
    }

    private func loadEngine() {
        engineGeneration += 1
        let generation = engineGeneration
        guard let path = models.activeModelPath() else {
            setStatus("Downloading model…")
            engineState = .downloading
            autoDownloadDefaultModel()
            return
        }
        let kind = models.activeModel?.engine
        // Drop the old engine first so whisper and Parakeet are never both
        // resident; push-to-talk is ignored while engine is nil.
        engine = nil
        setStatus("Loading model…")
        engineState = .loading
        slog("loading model (\(kind?.rawValue ?? "?")): \(path)")
        let modelName = models.activeModelID
        let loadStart = Date()
        // Only announce slow loads, so the usual sub-second load stays silent.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slowLoadThreshold) { [weak self] in
            guard let self, generation == self.engineGeneration, self.engine == nil,
                  self.engineState == .loading else { return }
            self.toast.show(
                "Loading \(modelName)… the first load after install can take ~20 s",
                seconds: 6
            )
        }
        Task.detached(priority: .userInitiated) {
            do {
                let start = Date()
                let engine = try TranscriptionEngines.load(modelPath: path, engine: kind)
                slog(String(format: "model loaded in %.1fs", -start.timeIntervalSinceNow))
                await MainActor.run { [weak self] in
                    guard let self, generation == self.engineGeneration else {
                        slog("model load superseded, discarding")
                        return
                    }
                    self.engine = engine
                    self.engineState = .ready
                    self.clearStatus()
                    if -loadStart.timeIntervalSinceNow >= Self.slowLoadThreshold {
                        self.toast.show("✓ \(modelName) ready — hold \(self.hotkey.key.title) to dictate")
                    }
                }
            } catch {
                slog("model load FAILED: \(error)")
                await MainActor.run { [weak self] in
                    guard let self, generation == self.engineGeneration else { return }
                    self.engineState = .failed
                    self.setStatus("Model load failed")
                }
            }
        }
    }

    @objc private func openRules() {
        NSWorkspace.shared.open(postProcessor.userRulesURL)
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
                toast.show("Will no longer start at login")
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
                toast.show("Will start at login")
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
        hotkey.latchKey = PTTKey.latch(for: choice)
        rebuildLatchMenu()
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
        setHotkeyStatus("hold \(choice.title) to dictate")
        toast.show("Push-to-talk key is now \(choice.title)")
    }

    private func rebuildLatchMenu() {
        guard let latchMenu = latchItem?.submenu else { return }
        latchMenu.removeAllItems()
        for id in LatchKeyResolver.choices(ptt: hotkey.key.id) {
            guard let choice = PTTKey.all.first(where: { $0.id == id }) else { continue }
            let item = NSMenuItem(title: choice.title, action: #selector(latchKeyAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice == hotkey.latchKey ? .on : .off
            latchMenu.addItem(item)
        }
    }

    @objc private func latchKeyAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let choice = PTTKey.all.first(where: { $0.id == id }), choice != hotkey.key else { return }
        PTTKey.saveLatch(choice)
        hotkey.latchKey = PTTKey.latch(for: hotkey.key)
        rebuildLatchMenu()
        toast.show("Hands-free: hold \(hotkey.key.title), tap \(hotkey.latchKey.title)")
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
        guard !recorder.isRecording else { return }
        guard engine != nil else {
            // Never ignore the key silently: say why nothing is happening.
            switch engineState {
            case .loading:
                toast.show("Model still loading — dictation will be ready in a few seconds")
            case .downloading:
                toast.show("Model still downloading — dictation starts when it's ready")
            case .failed:
                toast.show("Model failed to load — pick a model from the Susurro menu")
            case .ready:
                break
            }
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
        transcribeAndInsert(samples, releasePID: releaseApp?.processIdentifier,
                            releaseBundleID: releaseApp?.bundleIdentifier, expectedPID: nil)
    }

    /// Transcribe `samples` and insert the result into the focused field.
    /// `expectedPID` (hands-free chunks): if another app is frontmost by the
    /// time the text is ready, it goes to the clipboard instead of being typed
    /// into the wrong app. nil = today's push-to-talk behaviour, unchanged.
    @discardableResult
    private func transcribeAndInsert(_ samples: [Float], releasePID: pid_t?, releaseBundleID: String?,
                                     expectedPID: pid_t?, hfChunk: HFChunk? = nil) -> Task<Void, Never>? {
        guard let engine else { return nil }
        let postProcessor = postProcessor
        let cleaner = cleanupEnabled ? self.cleaner : nil
        // Text handling (BEA-648): read the focused field through
        // Accessibility while the engine transcribes; capped at 250 ms.
        // Smart Spacing is the stage's master toggle — off means no read and
        // the old context-free behaviour (sentence case only).
        var fieldTask: Task<FieldSnapshot?, Never>?
        if smartSpacingEnabled, !IsSecureEventInputEnabled(), let pid = releasePID {
            fieldTask = Task.detached(priority: .userInitiated) { await FocusedFieldReader.read(pid: pid, bundleID: releaseBundleID) }
        }
        let pendingFieldRead = fieldTask
        return Task.detached(priority: .userInitiated) {
            let transcript: String
            do {
                transcript = try engine.transcribe(samples: samples)
            } catch {
                slog("ptt: transcription FAILED: \(error)")
                await MainActor.run { [weak self] in
                    self?.toast.show("Transcription failed — see log")
                }
                transcript = ""
            }
            let raw = TranscriptFilter.stripHallucinations(transcript, engine: engine.kind)
            // Sentence case is deferred to the pre-insert stage, which can see
            // what precedes the cursor.
            var cleaned = raw.isEmpty ? "" : postProcessor.process(raw, applySentenceCase: false)
            if let cleaner, !cleaned.isEmpty {
                cleaned = await cleaner.clean(cleaned) ?? cleaned
            }
            slog("ptt: transcript: \(raw) -> \(cleaned)")
            let fieldRead = await pendingFieldRead?.value
            let autoCapitalize = postProcessor.autoCapitalizeEnabled
            // Hands-free joins (BEA-657): hold this chunk's final mark; if the
            // previous chunk's mark is held, decide it from a joint transcript.
            var joinedText: String?
            var heldBody: String?
            var processed = cleaned
            if let hfChunk, !cleaned.isEmpty {
                let step = await MainActor.run { [weak self] () -> (HeldMarkJoiner.Plan, HFChunk?)? in
                    guard let self else { return nil }
                    let previous = self.hfPrevChunk
                    let plan = self.hfJoiner.accept(cleaned, pid: expectedPID)
                    self.hfPrevChunk = hfChunk
                    return (plan, previous)
                }
                switch step {
                case (.fresh(let text), _)?:
                    processed = text
                case (.needsJoin(let held, let next), let previous?)?:
                    let clip = HandsFreeJoin.jointClip(a: previous.samples, aLastSpeechEnd: previous.lastSpeech,
                                                       b: hfChunk.samples, bFirstSpeechStart: hfChunk.firstSpeech)
                    let jointRaw = (try? engine.transcribe(samples: clip)) ?? ""
                    let joint = postProcessor.process(TranscriptFilter.stripHallucinations(jointRaw, engine: engine.kind),
                                                      applySentenceCase: false)
                    let decision = HandsFreeJoin.decide(previousBody: held.body, jointText: joint)
                    slog("handsfree: join decision=\(decision) held=\(held.mark)")
                    joinedText = HandsFreeJoin.joined(mark: held.mark, decision: decision, next: next)
                    heldBody = held.body
                    processed = next
                default:
                    break
                }
            }
            let joinText = joinedText
            let joinAfter = heldBody
            await MainActor.run { [weak self] in
                guard let self, !processed.isEmpty || joinText != nil else { return }
                // Secure input (password fields) silently blocks synthetic typing —
                // in that case copy regardless of the setting so the words aren't lost.
                let secureInputActive = IsSecureEventInputEnabled()
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if let expectedPID, frontmostPID != expectedPID {
                    // Hands-free chunk finished after an app switch: never type
                    // it somewhere the user didn't dictate into.
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    // A held mark travels with the copied words, never lost.
                    let copied = joinText.map { $0.trimmingCharacters(in: .whitespaces) } ?? processed
                    pasteboard.setString(copied, forType: .string)
                    self.hfJoiner.discard()
                    self.dictationMemory.clear()
                    self.toast.show("You switched apps — the last words were copied to the clipboard")
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
                        memory: frontmostPID.flatMap { self.dictationMemory.insertionIfStillFocused(pid: $0) },
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
                var text = stage.apply(processed, context)
                if let joinText, let joinAfter {
                    // Type the join in place only if the cursor is still right
                    // after the previous chunk's words. Unknown context (no AX,
                    // no memory) counts as in place: the session's own typing is
                    // the only thing that ran since. Moved cursor: B goes in as a
                    // fresh dictation and A's held mark is dropped (never typed
                    // at the wrong spot).
                    if HandsFreeJoin.isInPlace(before: context.before, previousBody: joinAfter) { text = joinText } else { slog("handsfree: cursor moved, join skipped") }
                }
                let readDetail = fieldRead?.detail ?? (pendingFieldRead == nil ? "notRead" : "timeout")
                TextHandlingLog.record("source=\(context.source.rawValue) provider=\(provider) app=\(releaseBundleID ?? "?") ax=\(readDetail) sameApp=\(frontmostPID == releasePID)")
                guard !text.isEmpty else { return }
                let typed = TextInjector.type(text)
                if !secureInputActive, typed, let frontmostPID {
                    // Where the insertion ended inside a cursorless value, so the
                    // next anchored lookup can tell repeated phrases apart.
                    var position: ValuePosition?
                    if context.source == .anchoredValue, let before = context.before,
                       let value = fieldRead?.value {
                        let typedLength = (text as NSString).length
                        position = ValuePosition(caretOffset: (before as NSString).length + typedLength,
                                                 valueLength: (value as NSString).length + typedLength)
                    }
                    self.dictationMemory.recordTyped(text, intoPID: frontmostPID, position: position)
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
        segmenter = PauseSegmenter()
        hfBuffer = []
        hfBufferStart = 0
        hfTotal = 0
        hfLastSpeech = nil
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
        hfFeed(recorder.takeAvailable())
        if let last = segmenter.lastSpeechSample, last != hfLastSpeech {
            hfLastSpeech = last
            overlay.setWarning(false)
            _ = hfEvent(.heardSpeech(at: now))
        }
        _ = hfEvent(.tick(at: now))
    }

    private func hfFeed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        hfBuffer.append(contentsOf: samples)
        hfTotal += samples.count
        for cut in segmenter.append(samples) { hfDispatch(cut) }
    }

    private func hfDispatch(_ cut: PauseSegmenter.Cut) {
        let sample = cut.sample, hasSpeech = cut.hasSpeech
        let n = sample - hfBufferStart
        guard n > 0, n <= hfBuffer.count else { return }
        // Drop a long pause's leading silence (BEA-657: 10-15 s thinking pauses).
        let start = HandsFreeJoin.trimmedStart(chunkStart: hfBufferStart, firstSpeech: cut.firstSpeech)
        let chunk = Array(hfBuffer[(start - hfBufferStart)..<n])
        hfBuffer.removeFirst(n)
        hfBufferStart = sample
        let info = HFChunk(samples: chunk,
                           firstSpeech: max(0, (cut.firstSpeech ?? start) - start),
                           lastSpeech: min(chunk.count, max(0, (cut.lastSpeech ?? sample) - start)))
        guard hasSpeech else { return }
        slog("handsfree: chunk \(chunk.count) samples")
        let previous = hfInsertChain
        let generation = hfGeneration
        let pid = hfPID, bundleID = hfBundleID
        // Chunks are transcribed and typed strictly in order.
        hfInsertChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, generation == self.hfGeneration else { return }
            await self.transcribeAndInsert(chunk, releasePID: pid, releaseBundleID: bundleID,
                                           expectedPID: pid, hfChunk: info)?.value
        }
    }

    private func hfEnd(insert: Bool, reason: HandsFreeMachine.StopReason?) {
        hfTimer?.invalidate()
        hfTimer = nil
        if let hfAppObserver { NSWorkspace.shared.notificationCenter.removeObserver(hfAppObserver) }
        hfAppObserver = nil
        let rest = recorder.stop()
        overlay.hide()
        if insert {
            hfFeed(rest)
            if let last = segmenter.finish(totalSamples: hfTotal) {
                hfDispatch(last)
            }
            // After the last chunk is typed, type its held end mark (BEA-657),
            // only if the same app is still frontmost.
            let previous = hfInsertChain
            let generation = hfGeneration
            let pid = hfPID
            hfInsertChain = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, generation == self.hfGeneration else { return }
                self.hfPrevChunk = nil
                guard let mark = self.hfJoiner.stop() else { return }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard let pid, front == pid, !IsSecureEventInputEnabled() else { return }
                if TextInjector.type(String(mark)) {
                    self.dictationMemory.recordTyped(String(mark), intoPID: pid)
                }
            }
        } else {
            hfGeneration += 1 // drop chunks not yet typed
            hfJoiner.discard() // and the held mark with them
            hfPrevChunk = nil
        }
        hfBuffer = []
        slog("handsfree: ended insert=\(insert) reason=\(String(describing: reason)) samples=\(hfTotal)")
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

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Susurro"
        let versionLine = build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
        // Model credit is required by CC-BY-4.0; shown regardless of the
        // active model since the weights ship as a menu option.
        alert.informativeText = "\(versionLine)\nMatthew Twomey\n\n\(ModelManager.parakeetAttribution)"
        // NSAlert's default icon falls back to a generic placeholder for
        // .accessory-policy (menu-bar-only, no Dock tile) apps like this one
        // — NSApp.applicationIconImage doesn't reliably resolve without a
        // Dock presence. Load the bundled icon directly instead.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            alert.icon = icon
        }
        // Clickable GitHub link as an accessory view. NSTextField opens
        // .link attributes itself once selectable — no target/action needed.
        let githubURL = "https://github.com/mtwomey/susurro"
        let link = NSTextField(labelWithAttributedString: NSAttributedString(
            string: githubURL,
            attributes: [
                .link: URL(string: githubURL)!,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        ))
        link.isSelectable = true
        link.frame = NSRect(x: 0, y: 0, width: 260, height: 18)
        alert.accessoryView = link
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// One hands-free chunk's audio plus where its speech starts/ends (relative
/// sample indices), kept so the next chunk can build a joint clip (BEA-657).
struct HFChunk: Sendable {
    let samples: [Float]
    let firstSpeech: Int
    let lastSpeech: Int
}
