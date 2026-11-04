import Foundation

/// Which engine a catalog entry runs on, and therefore what its on-disk
/// artifact looks like.
public enum EngineKind: String, Sendable, Equatable, CaseIterable {
    /// whisper.cpp: a single ggml `.bin` file.
    case whisper
    /// FluidAudio Parakeet TDT: a directory of Core ML `.mlmodelc` bundles
    /// plus a vocabulary file. Apple Silicon only.
    case parakeet

    /// Section header for this engine's group in the Model menu (and the
    /// Help window's description of it).
    public var menuSectionTitle: String {
        switch self {
        case .whisper: "Whisper (whisper.cpp)"
        case .parakeet: "NVIDIA Parakeet (Apple Silicon)"
        }
    }
}

/// One downloadable model. `storageName` is a file name for whisper models
/// and a directory name for Core ML models, always inside `modelsDir`.
public struct CatalogModel: Sendable, Identifiable, Equatable {
    public let id: String          // "small.en", "parakeet-tdt-v2"
    public let engine: EngineKind
    public let storageName: String // "ggml-small.en.bin" / "parakeet-tdt-0.6b-v2-coreml"
    public let approxMB: Int
    public let note: String
    /// Hugging Face repo the artifact comes from.
    public let repo: String
    /// For directory models: the top-level entries that must all be present
    /// for the model to count as downloaded (and that the downloader fetches).
    public let requiredEntries: [String]

    public init(id: String, engine: EngineKind, storageName: String, approxMB: Int,
                note: String, repo: String, requiredEntries: [String] = []) {
        self.id = id
        self.engine = engine
        self.storageName = storageName
        self.approxMB = approxMB
        self.note = note
        self.repo = repo
        self.requiredEntries = requiredEntries
    }

    /// Kept for call sites written against the whisper-only catalog.
    public var fileName: String { storageName }
    public var isDirectory: Bool { engine == .parakeet }

    static func whisper(_ id: String, _ fileName: String, _ approxMB: Int, _ note: String) -> CatalogModel {
        CatalogModel(id: id, engine: .whisper, storageName: fileName, approxMB: approxMB,
                     note: note, repo: "ggerganov/whisper.cpp")
    }
}

/// Source-compatible name from before the catalog carried engine kinds.
public typealias WhisperModel = CatalogModel

/// Manages model artifacts in ~/Library/Application Support/Susurro/models:
/// downloads from Hugging Face with progress, tracks the active model, deletes
/// unused ones. Whisper models are single ggml files; Parakeet is a Core ML
/// model directory fetched file-by-file by Susurro's own FileDownloader (not
/// FluidAudio's downloader, which reports no progress and writes to its own
/// Application Support folder) — see docs/PARAKEET_PLAN.md (BEA-634).
/// Verification is by exact byte count + successful engine load.
@MainActor
public final class ModelManager {
    public static let defaultModelID = "small.en"
    public static let parakeetV2ID = "parakeet-tdt-v2"
    /// Must equal FluidAudio's `Repo.parakeetV2.folderName`: `AsrModels.load`
    /// resolves files as `<parent>/<folderName>/...` (asserted in tests).
    public static let parakeetV2DirectoryName = "parakeet-tdt-0.6b-v2-coreml"

    public static let catalog: [CatalogModel] = [
        .whisper("tiny.en", "ggml-tiny.en.bin", 75, "fastest, roughest"),
        .whisper("base.en", "ggml-base.en.bin", 142, "fast, light"),
        .whisper("small.en", "ggml-small.en.bin", 466, "default — best balance"),
        .whisper("medium.en", "ggml-medium.en.bin", 1500, "high accuracy, slower"),
        .whisper("large-v3-turbo", "ggml-large-v3-turbo.bin", 1620, "most accurate Whisper, multilingual"),
        CatalogModel(
            id: parakeetV2ID, engine: .parakeet, storageName: parakeetV2DirectoryName,
            approxMB: 443, note: "English, most accurate",
            repo: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            requiredEntries: ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                              "JointDecision.mlmodelc", "parakeet_vocab.json"]
        ),
    ]

    public static func model(id: String) -> CatalogModel? {
        catalog.first(where: { $0.id == id })
    }

    /// Catalog entries this Mac can run: Parakeet (Core ML / ANE) is Apple Silicon only.
    public static func available(appleSilicon: Bool = isAppleSilicon) -> [CatalogModel] {
        catalog.filter { $0.engine != .parakeet || appleSilicon }
    }

    /// `available()` grouped by engine, in `EngineKind` declaration order and
    /// catalog order within each group; engines with no available models are
    /// omitted. Drives the sectioned Model menu.
    public static func menuSections(appleSilicon: Bool = isAppleSilicon) -> [(engine: EngineKind, models: [CatalogModel])] {
        let models = available(appleSilicon: appleSilicon)
        return EngineKind.allCases.compactMap { kind in
            let group = models.filter { $0.engine == kind }
            return group.isEmpty ? nil : (kind, group)
        }
    }

    /// Required CC-BY-4.0 attribution for the NVIDIA Parakeet model weights,
    /// shown in About. FluidAudio's Core ML conversion keeps the same licence.
    public static let parakeetAttribution = """
        Parakeet TDT 0.6B v2 speech model © NVIDIA, licensed under CC-BY-4.0 \
        (creativecommons.org/licenses/by/4.0). Core ML conversion by \
        FluidInference; run via FluidAudio (Apache 2.0).
        """

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Maps the persisted `activeModelID` to a catalog id. Every id ever written
    /// by a released build is a whisper catalog id and resolves to itself, so
    /// existing users see no change; nil or unknown values fall back to the
    /// default. Pure: the stored value is never rewritten.
    public static func resolveActiveModelID(_ stored: String?) -> String {
        guard let stored, model(id: stored) != nil else { return defaultModelID }
        return stored
    }

    private static let activeKey = "activeModelID"
    private static let legacyModelPath = NSString(
        string: "~/whisper.cpp/models/ggml-small.en.bin"
    ).expandingTildeInPath

    public let modelsDir: URL
    private let defaults: UserDefaults
    /// Fraction 0...1 per model id while a download is in flight.
    public private(set) var downloadProgress: [String: Double] = [:]
    public var onProgress: ((String, Double) -> Void)?

    public convenience init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Susurro/models")
        self.init(modelsDir: dir, defaults: .standard)
        seedFromLegacyIfNeeded()
    }

    /// Designated init; tests pass a scratch directory and a private suite.
    public init(modelsDir: URL, defaults: UserDefaults) {
        self.modelsDir = modelsDir
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }

    /// Dev-only convenience: adopt the whisper.cpp checkout's small.en via local
    /// copy instead of a 466 MB re-download. Gated behind SUSURRO_DEV_SEED_LEGACY_MODEL
    /// so production builds/launches never reach outside their own sandboxed data
    /// (and so `brew uninstall --zap` isn't silently undone on next launch). See
    /// docs/DEVELOPMENT.md for how `make run` sets this automatically.
    private func seedFromLegacyIfNeeded() {
        guard ProcessInfo.processInfo.environment["SUSURRO_DEV_SEED_LEGACY_MODEL"] == "1" else { return }
        guard let smallEN = Self.model(id: "small.en") else { return }
        let destination = path(for: smallEN)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
              fm.fileExists(atPath: Self.legacyModelPath) else { return }
        try? fm.copyItem(atPath: Self.legacyModelPath, toPath: destination.path)
        NSLog("[susurro] seeded small.en from legacy whisper.cpp checkout")
    }

    public var activeModelID: String {
        get { Self.resolveActiveModelID(defaults.string(forKey: Self.activeKey)) }
        set { defaults.set(newValue, forKey: Self.activeKey) }
    }

    public var activeModel: CatalogModel? { Self.model(id: activeModelID) }

    /// File (whisper) or directory (Core ML) for the model.
    public func path(for model: CatalogModel) -> URL {
        modelsDir.appendingPathComponent(model.storageName, isDirectory: model.isDirectory)
    }

    public func isDownloaded(_ model: CatalogModel) -> Bool {
        let fm = FileManager.default
        let root = path(for: model)
        guard model.isDirectory else { return fm.fileExists(atPath: root.path) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return model.requiredEntries.allSatisfy {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    public func isDownloading(_ model: CatalogModel) -> Bool {
        downloadProgress[model.id] != nil
    }

    /// Path for the active model. Nil means no model available at all. The legacy
    /// whisper.cpp checkout is never consulted here -- seedFromLegacyIfNeeded()
    /// (gated behind SUSURRO_DEV_SEED_LEGACY_MODEL) is the single, dev-only entry
    /// point for adopting it, so this stays a plain check of managed storage and
    /// behaves identically to a fresh install when that flag isn't set.
    public func activeModelPath() -> String? {
        guard let model = activeModel, isDownloaded(model) else { return nil }
        return path(for: model).path
    }

    public func delete(_ model: CatalogModel) {
        try? FileManager.default.removeItem(at: path(for: model))
        try? FileManager.default.removeItem(at: stagingPath(for: model))
    }

    private func stagingPath(for model: CatalogModel) -> URL {
        modelsDir.appendingPathComponent(".\(model.storageName).partial", isDirectory: true)
    }

    public func download(_ model: CatalogModel) async throws {
        guard !isDownloading(model), !isDownloaded(model) else { return }

        downloadProgress[model.id] = 0
        defer { downloadProgress[model.id] = nil }

        switch model.engine {
        case .whisper: try await downloadFile(model)
        case .parakeet: try await downloadDirectory(model)
        }
        NSLog("[susurro] model %@ downloaded", model.id)
    }

    private func report(_ modelID: String, _ fraction: Double) {
        guard downloadProgress[modelID] != nil else { return }
        downloadProgress[modelID] = fraction
        onProgress?(modelID, fraction)
    }

    private func downloadFile(_ model: CatalogModel) async throws {
        guard let url = URL(string: "https://huggingface.co/\(model.repo)/resolve/main/\(model.storageName)")
        else { return }
        let modelID = model.id
        let temporary = try await FileDownloader().download(from: url) { [weak self] fraction in
            Task { @MainActor [weak self] in self?.report(modelID, fraction) }
        }
        let destination = path(for: model)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Core ML directory: list the repo tree, fetch the required files into a
    /// hidden staging directory with byte-weighted progress, then rename it into
    /// place so a half-finished download never counts as `isDownloaded`.
    private func downloadDirectory(_ model: CatalogModel) async throws {
        let files = try await Self.fetchRepoFiles(repo: model.repo)
        let wanted = Self.filesToDownload(files, requiredEntries: model.requiredEntries)
        guard Set(wanted.map { Self.topLevelEntry($0.path) }) == Set(model.requiredEntries) else {
            throw FileDownloader.DownloadError.incomplete
        }
        let total = max(1, wanted.reduce(0) { $0 + $1.size })
        let fm = FileManager.default
        let staging = stagingPath(for: model)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var done: Int64 = 0
        let modelID = model.id
        for file in wanted {
            guard let url = URL(string: "https://huggingface.co/\(model.repo)/resolve/main/\(file.path)")
            else { throw FileDownloader.DownloadError.incomplete }
            let base = done, size = file.size
            let temporary = try await FileDownloader().download(from: url) { [weak self] fraction in
                let overall = Double(base) + fraction * Double(size)
                Task { @MainActor [weak self] in self?.report(modelID, overall / Double(total)) }
            }
            let destination = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: destination)
            done += file.size
            report(modelID, Double(done) / Double(total))
        }

        let destination = path(for: model)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
    }

    // MARK: - Hugging Face repo listing

    public struct RepoFile: Sendable, Equatable, Decodable {
        public let type: String
        public let path: String
        public let size: Int64

        public init(type: String, path: String, size: Int64) {
            self.type = type
            self.path = path
            self.size = size
        }
    }

    static func topLevelEntry(_ path: String) -> String {
        String(path.split(separator: "/", maxSplits: 1).first ?? "")
    }

    /// Files (not directories) under the required top-level entries, in a stable order.
    static func filesToDownload(_ files: [RepoFile], requiredEntries: [String]) -> [RepoFile] {
        let required = Set(requiredEntries)
        return files
            .filter { $0.type == "file" && required.contains(topLevelEntry($0.path)) }
            .sorted { $0.path < $1.path }
    }

    static func fetchRepoFiles(repo: String) async throws -> [RepoFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")
        else { throw FileDownloader.DownloadError.incomplete }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FileDownloader.DownloadError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode([RepoFile].self, from: data)
    }
}

/// URLSession download with progress via delegate, wrapped in async/await.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    enum DownloadError: Error {
        case badStatus(Int)
        case incomplete
    }

    func download(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progressHandler = progress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    private func resume(with result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        switch result {
        case .success(let url): continuation?.resume(returning: url)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            resume(with: .failure(DownloadError.badStatus(http.statusCode)))
            return
        }
        let expected = downloadTask.response?.expectedContentLength ?? -1
        let actual = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? nil
        if expected > 0, let actual, actual != expected {
            resume(with: .failure(DownloadError.incomplete))
            return
        }
        // Move out of URLSession's temp location before it's cleaned up
        let safe = FileManager.default.temporaryDirectory
            .appendingPathComponent("susurro-model-\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: safe)
            resume(with: .success(safe))
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resume(with: .failure(error))
        }
    }
}
