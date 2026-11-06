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

    // Production capture: AVAudioEngine. Alternatives (raw CoreAudio HAL, ScreenCaptureKit)
    // were evaluated and rejected — see docs/history/PLAN.md ("mic-mode pill"); their
    // recorders were deleted in R0 and live on in git history.
    private let recorder = AudioRecorder()
    private let overlay = OverlayController()
    private let postProcessor = PostProcessor()
    private let models = ModelManager()
    private let toast = ToastPanel()
    private let helpWindow = HelpWindowController()
    private var modelMenu: NSMenu!
    private var cleanupItem: NSMenuItem!

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
        c.onStateChange = { [unowned self] in self.updateStatusIcon() }
        c.setStatus = { [unowned self] in self.setStatus($0) }
        c.clearStatus = { [unowned self] in self.clearStatus() }
        c.rebuildModelMenu = { [unowned self] in self.rebuildModelMenu() }
        c.hotkeyTitle = { [unowned self] in self.hotkey.key.title }
        return c
    }()
    private var engine: (any TranscriptionEngine)? { engines.engine }
    private var axPollTimer: Timer?

    // Set once if the mic-permission callback reports denial. Sticky for the
    // rest of the run (TCC changes need a relaunch to take effect anyway) so
    // that transient model load/download status updates — which share the
    // same status menu item — can never silently clobber this more
    // important, persistent warning. See setStatus(_:enabled:action:).
    private var micAccessDenied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installDevFeedHook()
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

        engines.load()
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
        // engine via engines.load(). Keep HelpWindow's "Model" text in sync.
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
            engines.load() // hot-swap
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
            engines.downloadAndSwitch(to: model)
            rebuildModelMenu()
        }
    }

    /// Shows (or updates) the status menu item — inserted back into the menu
    /// if it isn't there, since `engines.load()` can run again later (model
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
        let (symbol, tip): (String, String) = switch engines.state {
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
            executor.memory.clear()
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

    /// Dev hook (BEA-677): feed a WAV into the running app instead of the
    /// microphone, as if it were one push-to-talk dictation into the
    /// frontmost app. Off unless `defaults write <bundle id> DevFeedHook -bool YES`.
    ///   scripts/feed_wav.sh clip.wav   (posts com.susurro.dev.feedWAV, object = "<bundle id>|<path>")
    private func installDevFeedHook() {
        guard settings.devFeedHook else { return }
        slog("dev: feed-WAV hook enabled")
        installDevProbeHook()
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
                    slog("dev: feed WAV refused — frontmost app is not the expected target")
                    return
                }
                do {
                    let samples = try AudioFileLoader.loadSamples(url: URL(fileURLWithPath: path))
                    slog("dev: feeding WAV (\(samples.count) samples)")
                    let pid = app?.processIdentifier, bundleID = app?.bundleIdentifier
                    self.insertionQueue.enqueue { [weak self] in
                        await self?.transcribeAndInsert(samples, releasePID: pid, releaseBundleID: bundleID,
                                                        expectedPID: nil)?.value
                    }
                } catch {
                    slog("dev: feed WAV failed: \(error)")
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
    private func installDevProbeHook() {
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
                if caretToEnd { Self.devMoveCaretToEnd(pid: app.processIdentifier) }
                let pid = app.processIdentifier
                let snapshot = FocusedFieldReader.readNow(pid: pid, bundleID: app.bundleIdentifier)
                let (context, provider) = InsertContext.resolve(
                    snapshot: snapshot, memory: self.executor.memory.insertionIfStillFocused(pid: pid),
                    pid: pid, bundleID: app.bundleIdentifier, engine: self.engine?.kind,
                    secureInput: IsSecureEventInputEnabled())
                let stage = TextHandlingStage.standard(smartSpacing: self.smartSpacingEnabled,
                                                       autoCapitalize: self.postProcessor.autoCapitalizeEnabled)
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
                slog("dev: context probe written")
            }
        }
    }

    /// Dev only: put the caret at the end of the target app's focused text
    /// element (AX selected range), so probes start from a known position.
    private static func devMoveCaretToEnd(pid: pid_t) {
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
typealias HFChunk = DictationPipeline.ChunkAudio

/// The real Inserter: CGEvent keystrokes via TextInjector (BEA-665).
@MainActor
final class KeystrokeInserter: Inserter {
    func type(_ text: String) -> Bool { TextInjector.type(text) }
    func deleteBackward(_ count: Int) { TextInjector.deleteBackward(count) }
}

/// The real Clipboard: NSPasteboard.general.
@MainActor
final class GeneralPasteboard: Clipboard {
    func set(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The real FrontmostAppProvider: NSWorkspace + Carbon secure-input state.
@MainActor
final class SystemFrontmostApp: FrontmostAppProvider {
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var secureInputActive: Bool { IsSecureEventInputEnabled() }
}
