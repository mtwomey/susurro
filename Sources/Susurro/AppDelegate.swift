import AppKit
import AVFoundation
import SusurroCore

func slog(_ msg: String) {
    NSLog("[susurro] %@", msg)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recordItem: NSMenuItem!
    private var hotkeyItem: NSMenuItem!

    // Production capture: AVAudioEngine. Alternatives evaluated and documented in
    // PLAN.md ("mic-mode pill"): HALAudioRecorder (raw CoreAudio — still pills),
    // SCKAudioRecorder (ScreenCaptureKit — no mic pill, but screen-recording pill,
    // Screen Recording permission, and 75–160 ms capture-start dead air).
    private let recorder = AudioRecorder()
    private let overlay = OverlayController()
    private let hotkey = HotkeyMonitor()
    private var engine: WhisperEngine?
    private var axPollTimer: Timer?

    // Temporary until ModelManager (M4)
    private let modelPath = NSString(string: "~/Git_Repos/whisper.cpp/models/ggml-small.en.bin").expandingTildeInPath

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

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Susurro",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        menu.autoenablesItems = false
        statusItem.menu = menu

        setUpHotkey()

        // Request mic permission up front, decoupled from the first recording,
        // so the permission dialog can't interrupt an in-flight engine start.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            slog("mic permission granted=\(granted)")
        }

        // Feed recorder levels to the overlay waveform (audio thread → main hop)
        recorder.levelHandler = { level in
            DispatchQueue.main.async { [weak self] in
                self?.overlay.push(level: level)
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

    private func loadEngine() {
        let path = modelPath
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
        hotkeyItem.title = "Hotkey: hold Right Option to dictate"
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
        Task.detached(priority: .userInitiated) {
            let text = (try? engine.transcribe(samples: samples)) ?? ""
            slog("ptt: transcript: \(text)")
            await MainActor.run {
                guard !text.isEmpty else { return }
                TextInjector.type(text)
                // Clipboard as a bonus safety net until history exists (v2)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
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
