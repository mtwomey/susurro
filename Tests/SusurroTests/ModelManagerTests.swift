import FluidAudio
import Foundation
import Testing
@testable import SusurroCore

@MainActor
@Suite struct ModelManagerTests {
    private func makeManager() -> (ModelManager, URL, UserDefaults) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("susurro-models-\(UUID().uuidString)")
        let suite = "susurro-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ModelManager(modelsDir: dir, defaults: defaults), dir, defaults)
    }

    private var parakeet: CatalogModel { ModelManager.model(id: ModelManager.parakeetV2ID)! }

    // MARK: catalog

    @Test func catalogIdsAreUnique() {
        let ids = ModelManager.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func whisperCatalogUnchanged() {
        let whisper = ModelManager.catalog.filter { $0.engine == .whisper }
        #expect(whisper.map(\.id) == ["tiny.en", "base.en", "small.en", "medium.en", "large-v3-turbo"])
        #expect(whisper.allSatisfy { $0.fileName == "ggml-\($0.id).bin" && !$0.isDirectory })
    }

    @Test func parakeetEntryIsCoreMLDirectory() {
        #expect(parakeet.engine == .parakeet)
        #expect(parakeet.isDirectory)
        #expect(parakeet.approxMB == 443)
        #expect(parakeet.repo == "FluidInference/parakeet-tdt-0.6b-v2-coreml")
        #expect(Set(parakeet.requiredEntries).isSuperset(of: ModelNames.ASR.requiredModels))
        #expect(parakeet.requiredEntries.contains(ModelNames.ASR.vocabularyFile))
    }

    @Test func parakeetDirectoryNameMatchesFluidAudio() {
        #expect(ModelManager.parakeetV2DirectoryName
                == AsrModels.defaultCacheDirectory(for: .v2).lastPathComponent)
    }

    @Test func parakeetHiddenOnIntel() {
        #expect(!ModelManager.available(appleSilicon: false).contains { $0.engine == .parakeet })
        #expect(ModelManager.available(appleSilicon: true).contains { $0.engine == .parakeet })
    }

    // MARK: activeModelID migration

    @Test func resolveKeepsEveryKnownId() {
        for model in ModelManager.catalog {
            #expect(ModelManager.resolveActiveModelID(model.id) == model.id)
        }
    }

    @Test func resolveFallsBackToDefault() {
        #expect(ModelManager.resolveActiveModelID(nil) == "small.en")
        #expect(ModelManager.resolveActiveModelID("bogus") == "small.en")
    }

    @Test func storedWhisperIdStillResolvesAndIsNotRewritten() {
        let (manager, _, defaults) = makeManager()
        #expect(manager.activeModelID == "small.en")
        defaults.set("medium.en", forKey: "activeModelID")
        #expect(manager.activeModelID == "medium.en")
        #expect(manager.activeModel?.engine == .whisper)
        defaults.set("removed-model", forKey: "activeModelID")
        #expect(manager.activeModelID == "small.en")
        #expect(defaults.string(forKey: "activeModelID") == "removed-model")
    }

    @Test func selectingParakeetPersists() {
        let (manager, _, defaults) = makeManager()
        manager.activeModelID = ModelManager.parakeetV2ID
        #expect(defaults.string(forKey: "activeModelID") == ModelManager.parakeetV2ID)
        #expect(manager.activeModel?.engine == .parakeet)
    }

    // MARK: storage

    @Test func whisperFileDownloadedAndActivePath() throws {
        let (manager, dir, _) = makeManager()
        let small = ModelManager.model(id: "small.en")!
        #expect(manager.path(for: small) == dir.appendingPathComponent("ggml-small.en.bin"))
        #expect(manager.activeModelPath() == nil)
        try Data([1]).write(to: manager.path(for: small))
        #expect(manager.isDownloaded(small))
        #expect(manager.activeModelPath() == manager.path(for: small).path)
        manager.delete(small)
        #expect(!manager.isDownloaded(small))
    }

    @Test func parakeetNeedsEveryRequiredEntry() throws {
        let (manager, dir, _) = makeManager()
        let root = manager.path(for: parakeet)
        #expect(root.standardizedFileURL.path
                == dir.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml").standardizedFileURL.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(!manager.isDownloaded(parakeet))
        for entry in parakeet.requiredEntries.dropLast() {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(entry),
                                                    withIntermediateDirectories: true)
        }
        #expect(!manager.isDownloaded(parakeet))
        try Data("{}".utf8).write(to: root.appendingPathComponent(parakeet.requiredEntries.last!))
        #expect(manager.isDownloaded(parakeet))
        manager.activeModelID = parakeet.id
        #expect(manager.activeModelPath() != nil)
        manager.delete(parakeet)
        #expect(!manager.isDownloaded(parakeet))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// Live: downloads ~464 MB from Hugging Face and loads it with FluidAudio.
    /// Run with `SUSURRO_LIVE_DOWNLOAD=1 swift test --filter liveParakeet`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUSURRO_LIVE_DOWNLOAD"] == "1"))
    func liveParakeetDownloadLoadsWithFluidAudio() async throws {
        let (manager, _, _) = makeManager()
        var seen: [Double] = []
        manager.onProgress = { _, fraction in seen.append(fraction) }
        try await manager.download(parakeet)
        #expect(manager.isDownloaded(parakeet))
        #expect(!seen.isEmpty)
        #expect((seen.max() ?? 0) > 0.99)
        let models = try await AsrModels.load(from: manager.path(for: parakeet), version: .v2)
        let asr = AsrManager(config: .default)
        try await asr.initialize(models: models)
        let text = try await asr.transcribe([Float](repeating: 0, count: 16_000 * 2), source: .microphone).text
        print("[live] progress callbacks: \(seen.count), silence transcript: '\(text)'")
        manager.delete(parakeet)
        #expect(!manager.isDownloaded(parakeet))
    }

    @Test func repoListingFilteredToRequiredFiles() {
        let listing: [ModelManager.RepoFile] = [
            .init(type: "file", path: "README.md", size: 10),
            .init(type: "directory", path: "Encoder.mlmodelc", size: 0),
            .init(type: "file", path: "Encoder.mlmodelc/weights/weight.bin", size: 400),
            .init(type: "file", path: "Encoder.mlmodelc/model.mil", size: 5),
            .init(type: "file", path: "ParakeetEncoder_v2.mlmodelc/model.mil", size: 7),
            .init(type: "file", path: "parakeet_vocab.json", size: 3),
        ]
        let wanted = ModelManager.filesToDownload(
            listing, requiredEntries: ["Encoder.mlmodelc", "parakeet_vocab.json"])
        #expect(wanted.map(\.path) == ["Encoder.mlmodelc/model.mil",
                                        "Encoder.mlmodelc/weights/weight.bin",
                                        "parakeet_vocab.json"])
    }
}
