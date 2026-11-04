// susurro-cli — transcription engine test & corpus regression harness.
//
// Usage: susurro-cli [--post] <model.bin | parakeet-model-dir> <audio-file> [audio-file...]
//
// --post also runs the app's output pipeline (engine-aware TranscriptFilter +
// PostProcessor with the bundled default rules, never the user's rules.json)
// and prints "raw<TAB>processed" per clip — the engine-comparison harness for
// verbal punctuation (BEA-636).

import Foundation
import SusurroCore

func errPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let post = CommandLine.arguments.contains("--post")
let args = CommandLine.arguments.filter { $0 != "--post" }
guard args.count >= 3 else {
    errPrint("usage: susurro-cli [--post] <model.bin | parakeet-model-dir> <audio-file> [audio-file...]")
    exit(1)
}

do {
    let loadStart = Date()
    let engine: any TranscriptionEngine = try TranscriptionEngines.load(modelPath: args[1])
    errPrint(String(format: "[model loaded in %.2fs]", -loadStart.timeIntervalSinceNow))

    // Bundled defaults only: a fresh temp path makes PostProcessor seed it
    // from DefaultRules, so results don't depend on the developer's rules.json.
    let processor = PostProcessor(userRulesURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("susurro-cli-\(UUID().uuidString)/rules.json"))
    for path in args.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let samples = try AudioFileLoader.loadSamples(url: url)
        let audioSeconds = Double(samples.count) / Double(TranscriptionEngines.sampleRate)

        let t0 = Date()
        let text = try engine.transcribe(samples: samples)
        let elapsed = -t0.timeIntervalSinceNow

        errPrint(String(format: "[%@: %.2fs audio | %.2fs | %.1fx realtime]",
                        url.lastPathComponent, audioSeconds, elapsed, audioSeconds / max(elapsed, 0.001)))
        if post {
            let filtered = TranscriptFilter.stripHallucinations(text, engine: engine.kind)
            let processed = filtered.isEmpty ? "" : processor.process(filtered)
            print(text + "\t" + processed.replacingOccurrences(of: "\n", with: "\\n"))
        } else {
            print(text)
        }
    }
} catch {
    errPrint("error: \(error)")
    exit(1)
}
