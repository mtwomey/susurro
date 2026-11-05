// susurro-cli — transcription engine test & corpus regression harness.
//
// Usage:
//   susurro-cli [--post] <model.bin | parakeet-model-dir> <audio-file> [audio-file...]
//   susurro-cli [--post] --engine whisper|parakeet [--model <path>] <audio-file> [audio-file...]
//
// --engine picks the backend explicitly. Without --model it uses the app's
// managed model: small.en for whisper, parakeet-tdt-v2 for parakeet (falling
// back to FluidAudio's own cache dir for Parakeet). It never downloads.
//
// --post also runs the app's output pipeline (engine-aware TranscriptFilter +
// PostProcessor with the bundled default rules, never the user's rules.json)
// and prints "raw<TAB>processed" per clip — the engine-comparison harness for
// verbal punctuation (BEA-636). Per-clip timing goes to stderr; scripts/ab_engines.py
// (BEA-637) parses it for the A/B accuracy/latency report.

import Foundation
import SusurroCore

func errPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let usage = """
usage: susurro-cli [--post] <model.bin | parakeet-model-dir> <audio-file> [audio-file...]
       susurro-cli [--post] --engine whisper|parakeet [--model <path>] <audio-file> [audio-file...]
"""

var post = false
var engineKind: EngineKind?
var modelPath: String?
var positional: [String] = []
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--post": post = true
    case "--engine":
        guard let v = it.next(), let k = EngineKind(rawValue: v) else {
            errPrint("--engine must be one of: \(EngineKind.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(1)
        }
        engineKind = k
    case "--model":
        guard let v = it.next() else { errPrint(usage); exit(1) }
        modelPath = v
    case "-h", "--help": print(usage); exit(0)
    default: positional.append(a)
    }
}

/// The app's managed storage location for a catalog model (no download).
@MainActor func managedPath(for kind: EngineKind) -> String? {
    let id = kind == .parakeet ? ModelManager.parakeetV2ID : ModelManager.defaultModelID
    guard let model = ModelManager.model(id: id) else { return nil }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let candidates = [
        support.appendingPathComponent("Susurro/models/\(model.storageName)").path,
        // FluidAudio's own cache (BEA-632 spike) — handy on dev machines.
        support.appendingPathComponent("FluidAudio/Models/\(ModelManager.parakeetV2DirectoryName)").path,
    ]
    return candidates.prefix(kind == .parakeet ? 2 : 1).first { FileManager.default.fileExists(atPath: $0) }
}

if engineKind == nil && modelPath == nil {
    // Legacy form: first positional is the model path.
    guard !positional.isEmpty else { errPrint(usage); exit(1) }
    modelPath = positional.removeFirst()
} else if modelPath == nil, let k = engineKind {
    guard let p = managedPath(for: k) else {
        errPrint("error: no downloaded \(k.rawValue) model found; pass --model <path> or download it in the app")
        exit(1)
    }
    modelPath = p
}
guard let modelPath, !positional.isEmpty else { errPrint(usage); exit(1) }

/// Dev-only trailing pad for the end-of-sentence punctuation sweep (BEA-643),
/// so pad lengths can be compared without a rebuild per value. Unset = no pad.
///   SUSURRO_DEV_PAD_MS     trailing pad length in ms
///   SUSURRO_DEV_PAD_ALIGN  round the padded total up to a multiple of N samples
///   SUSURRO_DEV_PAD_NOISE  pad with seeded uniform noise of this amplitude instead of zeros
func devPadded(_ samples: [Float]) -> [Float] {
    let env = ProcessInfo.processInfo.environment
    let ms = Double(env["SUSURRO_DEV_PAD_MS"] ?? "") ?? 0
    let align = Int(env["SUSURRO_DEV_PAD_ALIGN"] ?? "") ?? 0
    let noise = Float(env["SUSURRO_DEV_PAD_NOISE"] ?? "") ?? 0
    var count = Int(ms * Double(TranscriptionEngines.sampleRate) / 1000)
    if align > 0 { count += (align - (samples.count + count) % align) % align }
    guard count > 0 else { return samples }
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    let pad = (0..<count).map { _ -> Float in
        guard noise > 0 else { return 0 }
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * noise
    }
    return samples + pad
}

do {
    let loadStart = Date()
    let engine: any TranscriptionEngine = try TranscriptionEngines.load(modelPath: modelPath, engine: engineKind)
    errPrint(String(format: "[%@ model loaded in %.2fs: %@]", engine.kind.rawValue, -loadStart.timeIntervalSinceNow, modelPath))

    // Bundled defaults only: a fresh temp path makes PostProcessor seed it
    // from DefaultRules, so results don't depend on the developer's rules.json.
    let processor = PostProcessor(userRulesURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("susurro-cli-\(UUID().uuidString)/rules.json"))
    for path in positional {
        let url = URL(fileURLWithPath: path)
        let samples = devPadded(try AudioFileLoader.loadSamples(url: url))
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
