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

/// Records raw transcripts in call order (dev golden capture, BEA-664).
final class RecordingEngine: TranscriptionEngine, @unchecked Sendable {
    static var sampleRate: Int { TranscriptionEngines.sampleRate }
    let inner: any TranscriptionEngine
    private(set) var calls: [String] = []
    init(_ inner: any TranscriptionEngine) { self.inner = inner }
    var kind: EngineKind { inner.kind }
    func reset() { calls = [] }
    func transcribe(samples: [Float]) throws -> String {
        let text = try inner.transcribe(samples: samples)
        calls.append(text)
        return text
    }
}

func errPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let usage = """
usage: susurro-cli [--post] <model.bin | parakeet-model-dir> <audio-file> [audio-file...]
       susurro-cli [--post] --engine whisper|parakeet [--model <path>] <audio-file> [audio-file...]
       susurro-cli --xjoin [--gap <s>] --engine parakeet <dictation1> <dictation2> [...]
         (consecutive separate dictations into one field, BEA-677; prints JSON)
"""

var post = false
var xJoin = false      // --xjoin: files are consecutive separate dictations (BEA-677)
var xGap: Double = 3
var handsFree = false   // --handsfree: segment each file like the app's hands-free pump and join (BEA-657)
var minPause: Double?
var engineKind: EngineKind?
var modelPath: String?
var positional: [String] = []
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--post": post = true
    case "--handsfree": handsFree = true
    case "--xjoin": xJoin = true
    case "--gap":
        guard let v = it.next(), let d = Double(v) else { errPrint(usage); exit(1) }
        xGap = d
    case "--min-pause":
        guard let v = it.next(), let d = Double(v) else { errPrint(usage); exit(1) }
        minPause = d
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
    let loaded: any TranscriptionEngine = try TranscriptionEngines.load(modelPath: modelPath, engine: engineKind)
    // Dev: SUSURRO_DEV_RECORD_RAW=<path> logs every raw engine transcript in
    // call order (one JSON line per input file) so golden tests can replay a
    // run with a scripted fake engine (BEA-664). Unset = no change.
    let recordPath = ProcessInfo.processInfo.environment["SUSURRO_DEV_RECORD_RAW"]
    let recorder = recordPath.map { _ in RecordingEngine(loaded) }
    let engine: any TranscriptionEngine = recorder ?? loaded
    errPrint(String(format: "[%@ model loaded in %.2fs: %@]", engine.kind.rawValue, -loadStart.timeIntervalSinceNow, modelPath))

    // Bundled defaults only: a fresh temp path makes PostProcessor seed it
    // from DefaultRules, so results don't depend on the developer's rules.json.
    let processor = PostProcessor(userRulesURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("susurro-cli-\(UUID().uuidString)/rules.json"))
    // The app's own pipeline (BEA-664): no LLM cleaner, so output stays
    // deterministic and comparable across runs.
    let pipeline = DictationPipeline(engine: engine, postProcessor: processor)
    if xJoin {
        // Mirrors AppDelegate's push-to-talk insert path for separate
        // dictations into one untouched field: text stage with the field's
        // text as context, then the cross-dictation guard + joint-clip join.
        let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)
        var field = "", decisions: [String] = [], texts: [String] = []
        var prev: (record: CrossDictationJoin.Previous, samples: [Float], last: Int)?
        var clock = Date(timeIntervalSince1970: 0)
        for path in positional {
            let samples = try AudioFileLoader.loadSamples(url: URL(fileURLWithPath: path))
            let processed = pipeline.clean(try engine.transcribe(samples: samples))
            texts.append(processed)
            guard !processed.isEmpty else { continue }
            let startedAt = clock.addingTimeInterval(xGap)
            let ctx = field.isEmpty ? InsertContext(before: nil, source: .none)
                                    : InsertContext(before: field, after: "", source: .anchoredValue)
            var text = stage.apply(processed, ctx)
            let bounds = CrossDictationJoin.speechBounds(samples)
            var jointTime: Duration?
            let decision = try pipeline.crossDecision(
                previous: prev?.record, previousAudio: prev.map { .init(samples: $0.samples, firstSpeech: 0, lastSpeech: $0.last) },
                samples: samples, pid: 1, startedAt: startedAt, jointSeconds: &jointTime)
            let verdict = CrossDictationJoin.check(previous: prev?.record, current: .init(
                pid: 1, fieldID: nil, startedAt: startedAt, before: field.isEmpty ? nil : field, after: ""))
            if case .eligible = verdict, let decision {
                let edit = CrossDictationJoin.edit(decision: decision, next: text)
                field.removeLast(edit.deleteBackward)
                text = edit.text
            }
            decisions.append(CrossDictationJoin.logLine(verdict: verdict, gap: prev == nil ? nil : xGap, decision: decision))
            field += text
            clock = startedAt.addingTimeInterval(Double(samples.count) / 16_000)
            prev = bounds.map { (CrossDictationJoin.Previous(typed: text, pid: 1, fieldID: nil, endedAt: clock), samples, $0.last) }
        }
        let out: [String: Any] = ["texts": texts, "decisions": decisions, "typed": field]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    }
    if handsFree {
        // Mirrors AppDelegate's hands-free pump: PauseSegmenter cuts, each chunk
        // transcribed alone (filter + PostProcessor, no sentence case), held
        // marks decided from a joint clip. Prints one JSON object per file.
        for path in positional {
            let samples = try AudioFileLoader.loadSamples(url: URL(fileURLWithPath: path))
            recorder?.reset()
            let r = try pipeline.replayHandsFree(samples, minPause: minPause)
            if let recorder, let recordPath {
                let line = try JSONSerialization.data(withJSONObject: ["file": (path as NSString).lastPathComponent,
                                                                       "raw": recorder.calls], options: [.sortedKeys])
                let h = FileHandle(forWritingAtPath: recordPath) ?? {
                    FileManager.default.createFile(atPath: recordPath, contents: nil)
                    return FileHandle(forWritingAtPath: recordPath)!
                }()
                h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); h.closeFile()
            }
            let out: [String: Any] = ["file": (path as NSString).lastPathComponent, "chunks": r.chunks,
                                      "decisions": r.decisions, "typed": r.typed, "jointSeconds": r.jointSeconds]
            let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        }
        exit(0)
    }
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
            let processed = pipeline.postProcessed(text)
            print(text + "\t" + processed.replacingOccurrences(of: "\n", with: "\\n"))
        } else {
            print(text)
        }
    }
} catch {
    errPrint("error: \(error)")
    exit(1)
}
