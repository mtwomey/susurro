import AppKit
import SusurroCore
import UserNotifications

/// Model lifecycle (review F1/R4): owns the loaded engine, the load
/// generation, the user-visible engine state, and the load/download toasts
/// and notifications. AppDelegate wires the menu status hooks.
@MainActor
final class EngineController {
    /// Why there's no engine right now, for user-visible feedback. The menu
    /// status item alone is invisible unless the menu is open, and a cold
    /// Parakeet load (Core ML compile) takes ~20 s, so without this the app
    /// looked broken: push-to-talk silently did nothing.
    enum State { case loading, downloading, failed, ready }

    private(set) var engine: (any TranscriptionEngine)?
    private(set) var state: State = .loading {
        didSet { onStateChange() }
    }
    // Bumped on every load() call; a load that finishes after a newer one
    // started (fast menu switching) is discarded instead of winning.
    private var generation = 0

    private let models: ModelManager
    private let toast: ToastPanel
    private let tuning: Tuning

    // Host hooks (menu status item, model menu, hotkey title).
    var onStateChange: () -> Void = {}
    var setStatus: (String) -> Void = { _ in }
    var clearStatus: () -> Void = {}
    var rebuildModelMenu: () -> Void = {}
    var hotkeyTitle: () -> String = { "" }

    init(models: ModelManager, toast: ToastPanel, tuning: Tuning = .default) {
        self.models = models
        self.toast = toast
        self.tuning = tuning
    }

    /// The toast explaining why push-to-talk did nothing; nil when ready.
    var unavailableMessage: String? {
        guard engine == nil else { return nil }
        switch state {
        case .loading: return "Model still loading — dictation will be ready in a few seconds"
        case .downloading: return "Model still downloading — dictation starts when it's ready"
        case .failed: return "Model failed to load — pick a model from the Susurro menu"
        case .ready: return nil
        }
    }

    func load() {
        generation += 1
        let generation = generation
        guard let path = models.activeModelPath() else {
            setStatus("Downloading model…")
            state = .downloading
            autoDownloadDefaultModel()
            return
        }
        let kind = models.activeModel?.engine
        // Drop the old engine first so whisper and Parakeet are never both
        // resident; push-to-talk is ignored while engine is nil.
        engine = nil
        setStatus("Loading model…")
        state = .loading
        Log.engine.event("loading model (\(kind?.rawValue ?? "?")): \(path)")
        let modelName = models.activeModelID
        let loadStart = Date()
        let slow = tuning.slowLoadThreshold
        // Only announce slow loads, so the usual sub-second load stays silent.
        DispatchQueue.main.asyncAfter(deadline: .now() + slow) { [weak self] in
            guard let self, generation == self.generation, self.engine == nil,
                  self.state == .loading else { return }
            self.toast.show(
                "Loading \(modelName)… the first load after install can take ~20 s",
                seconds: 6
            )
        }
        Task.detached(priority: .userInitiated) {
            do {
                let start = Date()
                let engine = try TranscriptionEngines.load(modelPath: path, engine: kind)
                Log.engine.event(String(format: "model loaded in %.1fs", -start.timeIntervalSinceNow))
                await MainActor.run { [weak self] in
                    guard let self, generation == self.generation else {
                        Log.engine.event("model load superseded, discarding")
                        return
                    }
                    self.engine = engine
                    self.state = .ready
                    self.clearStatus()
                    if -loadStart.timeIntervalSinceNow >= slow {
                        self.toast.show("✓ \(modelName) ready — hold \(self.hotkeyTitle()) to dictate")
                    }
                }
            } catch {
                Log.engine.failure("model load FAILED: \(error)")
                await MainActor.run { [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.state = .failed
                    self.setStatus("Model load failed")
                }
            }
        }
    }

    /// Model menu click on a model that isn't downloaded yet: download, then
    /// auto-switch + notification (attention may be elsewhere).
    func downloadAndSwitch(to model: CatalogModel) {
        Task { [weak self] in
            do {
                try await self?.models.download(model)
                guard let self else { return }
                self.models.activeModelID = model.id
                self.rebuildModelMenu()
                self.load()
                self.notify("Model ready",
                            "\(model.id) downloaded — Susurro is now using it.")
            } catch {
                Log.engine.failure("model download failed: \(error)")
                self?.notify("Model download failed",
                             "\(model.id): \(error.localizedDescription)")
                self?.rebuildModelMenu()
            }
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
                    self.load()
                    self.notify("Susurro is ready",
                                "small.en downloaded — hold your push-to-talk key to dictate.")
                }
                self.rebuildModelMenu()
            } catch {
                Log.engine.failure("auto-download failed: \(error)")
                self?.state = .failed
                self?.setStatus("Model download failed — retry from the Model menu")
                self?.notify("Model download failed",
                             "Open the Model menu to retry. \(error.localizedDescription)")
                self?.rebuildModelMenu()
            }
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
}
