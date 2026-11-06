import AppKit
import ServiceManagement
import SusurroCore

/// The menu-bar status item and its menu (review R4): construction, the
/// status line (model load/download, mic denied), model / key / toggle
/// actions. Moved out of AppDelegate unchanged.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var recordItem: NSMenuItem!
    private var hotkeyItem: NSMenuItem!
    private var latchItem: NSMenuItem!
    private var modelMenu: NSMenu!
    private var cleanupItem: NSMenuItem!

    private let models: ModelManager
    private let toast: ToastPanel
    private let hotkey: HotkeyMonitor
    private let engines: () -> EngineController
    private let postProcessor: PostProcessor
    private let helpWindow: HelpWindowController
    private let settings: Settings
    /// The AI cleaner, when this Mac has one (macOS 26+).
    var cleaner: () -> (any TextCleaning)? = { nil }
    /// Smart Spacing turned off: forget the self-tracked dictation memory.
    var onSmartSpacingOff: () -> Void = {}

    // Set once if the mic-permission callback reports denial. Sticky for the
    // rest of the run (TCC changes need a relaunch to take effect anyway) so
    // that transient model load/download status updates — which share the
    // same status menu item — can never silently clobber this more
    // important, persistent warning. See setStatus(_:enabled:action:).
    private var micAccessDenied = false

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

    init(models: ModelManager, toast: ToastPanel, hotkey: HotkeyMonitor,
         engines: @escaping () -> EngineController, postProcessor: PostProcessor,
         helpWindow: HelpWindowController, settings: Settings) {
        self.models = models
        self.toast = toast
        self.hotkey = hotkey
        self.engines = engines
        self.postProcessor = postProcessor
        self.helpWindow = helpWindow
        self.settings = settings
    }

    func build() {
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
    }

    /// Mic permission denied: a sticky, clickable status line.
    func micDenied() {
        micAccessDenied = true
        setStatus(
            "Mic access denied — click to open Settings",
            enabled: true,
            action: #selector(StatusMenuController.openMicSettings),
            overridesMicWarning: true
        )
    }

    @objc private func showAbout() { Alerts.showAbout() }

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

    func rebuildModelMenu() {
        modelMenu.removeAllItems()
        // One menu, sectioned by engine (Parakeet is Apple Silicon only;
        // menuSections() omits it elsewhere). Picking any entry hot-swaps the
        // engine via engines().load(). Keep HelpWindow's "Model" text in sync.
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
            engines().load() // hot-swap
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
            engines().downloadAndSwitch(to: model)
            rebuildModelMenu()
        }
    }

    /// Shows (or updates) the status menu item — inserted back into the menu
    /// if it isn't there, since `engines().load()` can run again later (model
    /// hot-swap, retry after failure) after `clearStatus()` removed it.
    ///
    /// `recordItem` is shared between two unrelated concerns: transient
    /// model load/download status, and the persistent mic-access-denied
    /// warning. Without `overridesMicWarning`, a fast model load finishing
    /// right after mic access was denied would silently clobber that
    /// warning with "Loading model…"/clear it entirely — leaving no menu
    /// indication of why dictation still doesn't work. Only the
    /// mic-permission callback passes `overridesMicWarning: true`.
    func setStatus(
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
    func setHotkeyStatus(_ text: String) {
        hotkeyItem.title = "(\(text))"
    }

    /// Removes the status item once there's nothing to report — dictation is
    /// ready and available via the push-to-talk hotkey. Never clears a
    /// mic-access-denied warning (see setStatus) — that's sticky for the
    /// rest of the run.
    /// Menu bar icon reflects engine readiness, so a loading app doesn't look
    /// identical to a ready one.
    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let (symbol, tip): (String, String) = switch engines().state {
        case .ready: ("waveform.circle", "Susurro")
        case .loading: ("hourglass.circle", "Susurro — loading model…")
        case .downloading: ("arrow.down.circle", "Susurro — downloading model…")
        case .failed: ("exclamationmark.circle", "Susurro — model load failed")
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
    }

    func clearStatus() {
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
                if let cleaner = cleaner() {
                    Task.detached { cleaner.prewarm() }
                }
            } else {
                toast.show("AI Cleanup off")
            }
        case .appleIntelligenceNotEnabled:
            Alerts.showAppleIntelligenceInstructions()
        default:
            break
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
            onSmartSpacingOff()
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
            Log.dictation.failure("login item toggle failed: \(error)")
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
        for id in ModeKeyResolver.choices(ptt: hotkey.key.id) {
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
}
