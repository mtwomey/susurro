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

    private let recorder = AudioRecorder()
    private var engine: WhisperEngine?

    // Temporary until ModelManager (M4)
    private let modelPath = NSString(string: "~/Git_Repos/whisper.cpp/models/ggml-small.en.bin").expandingTildeInPath

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

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Susurro",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Request mic permission up front, decoupled from the first recording,
        // so the permission dialog can't interrupt an in-flight engine start.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            slog("mic permission granted=\(granted)")
        }

        loadEngine()
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
