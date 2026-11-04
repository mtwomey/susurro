// parakeet-spike — BEA-632 feasibility harness for FluidAudio Parakeet TDT v2.
//
// Usage: parakeet-spike <audio-file> [audio-file...]
// Each file is transcribed twice: pass 1 (first-inference) and pass 2 (warm).

import Foundation
import SusurroCore

func errPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let files = CommandLine.arguments.dropFirst()
guard !files.isEmpty else {
    errPrint("usage: parakeet-spike <audio-file> [audio-file...]")
    exit(1)
}

do {
    let loadStart = Date()
    let engine = try ParakeetEngine.downloadAndLoad()
    errPrint(String(format: "[model loaded in %.2fs from %@]", -loadStart.timeIntervalSinceNow,
                    ParakeetEngine.fluidAudioCacheDirectory.path))

    for pass in 1...2 {
        for path in files {
            let url = URL(fileURLWithPath: path)
            let samples = try AudioFileLoader.loadSamples(url: url)
            let audioSeconds = Double(samples.count) / Double(WhisperEngine.sampleRate)
            let t0 = Date()
            let text = try engine.transcribe(samples: samples)
            let elapsed = -t0.timeIntervalSinceNow
            errPrint(String(format: "[pass %d %@: %.2fs audio | %.3fs | %.1fx realtime]", pass,
                            url.lastPathComponent, audioSeconds, elapsed, audioSeconds / max(elapsed, 0.001)))
            if pass == 1 { print("\(url.lastPathComponent): \(text)") }
        }
    }
} catch {
    errPrint("error: \(error)")
    exit(1)
}
