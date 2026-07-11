// susurro-cli — whisper bridge test & corpus regression harness.
//
// Usage: susurro-cli <model.bin> <audio-file> [audio-file...]

import Foundation
import SusurroCore

func errPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    errPrint("usage: susurro-cli <model.bin> <audio-file> [audio-file...]")
    exit(1)
}

do {
    let loadStart = Date()
    let engine = try WhisperEngine(modelPath: args[1])
    errPrint(String(format: "[model loaded in %.2fs]", -loadStart.timeIntervalSinceNow))

    for path in args.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let samples = try AudioFileLoader.loadSamples(url: url)
        let audioSeconds = Double(samples.count) / Double(WhisperEngine.sampleRate)

        let t0 = Date()
        let text = try engine.transcribe(samples: samples)
        let elapsed = -t0.timeIntervalSinceNow

        errPrint(String(format: "[%@: %.2fs audio | %.2fs | %.1fx realtime]",
                        url.lastPathComponent, audioSeconds, elapsed, audioSeconds / max(elapsed, 0.001)))
        print(text)
    }
} catch {
    errPrint("error: \(error)")
    exit(1)
}
