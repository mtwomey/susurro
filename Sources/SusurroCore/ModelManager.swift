import Foundation

public struct WhisperModel: Sendable, Identifiable, Equatable {
    public let id: String        // "small.en"
    public let fileName: String  // "ggml-small.en.bin"
    public let approxMB: Int
    public let note: String
}

/// Manages whisper model files in ~/Library/Application Support/Susurro/models:
/// downloads from Hugging Face with progress, tracks the active model, deletes
/// unused ones. Verification is by exact byte count + successful engine load
/// (a corrupt ggml file fails to load, which the app surfaces).
@MainActor
public final class ModelManager {
    public static let catalog: [WhisperModel] = [
        WhisperModel(id: "tiny.en",  fileName: "ggml-tiny.en.bin",
                     approxMB: 75,   note: "fastest, roughest"),
        WhisperModel(id: "base.en",  fileName: "ggml-base.en.bin",
                     approxMB: 142,  note: "fast, light"),
        WhisperModel(id: "small.en", fileName: "ggml-small.en.bin",
                     approxMB: 466,  note: "default — best balance"),
        WhisperModel(id: "medium.en", fileName: "ggml-medium.en.bin",
                     approxMB: 1500, note: "high accuracy, slower"),
        WhisperModel(id: "large-v3-turbo", fileName: "ggml-large-v3-turbo.bin",
                     approxMB: 1620, note: "best accuracy, multilingual"),
    ]

    private static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
    private static let activeKey = "activeModelID"
    private static let legacyModelPath = NSString(
        string: "~/Git_Repos/whisper.cpp/models/ggml-small.en.bin"
    ).expandingTildeInPath

    public let modelsDir: URL
    /// Fraction 0...1 per model id while a download is in flight.
    public private(set) var downloadProgress: [String: Double] = [:]
    public var onProgress: ((String, Double) -> Void)?

    public init() {
        modelsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Susurro/models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        seedFromLegacyIfNeeded()
    }

    /// Dev-only convenience: adopt the whisper.cpp checkout's small.en via local
    /// copy instead of a 466 MB re-download. Gated behind SUSURRO_DEV_SEED_LEGACY_MODEL
    /// so production builds/launches never reach outside their own sandboxed data
    /// (and so `brew uninstall --zap` isn't silently undone on next launch). See
    /// docs/DEVELOPMENT.md for how `make run` sets this automatically.
    private func seedFromLegacyIfNeeded() {
        guard ProcessInfo.processInfo.environment["SUSURRO_DEV_SEED_LEGACY_MODEL"] == "1" else { return }
        guard let smallEN = Self.catalog.first(where: { $0.id == "small.en" }) else { return }
        let destination = path(for: smallEN)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
              fm.fileExists(atPath: Self.legacyModelPath) else { return }
        try? fm.copyItem(atPath: Self.legacyModelPath, toPath: destination.path)
        NSLog("[susurro] seeded small.en from legacy whisper.cpp checkout")
    }

    public var activeModelID: String {
        get { UserDefaults.standard.string(forKey: Self.activeKey) ?? "small.en" }
        set { UserDefaults.standard.set(newValue, forKey: Self.activeKey) }
    }

    public func path(for model: WhisperModel) -> URL {
        modelsDir.appendingPathComponent(model.fileName)
    }

    public func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: path(for: model).path)
    }

    public func isDownloading(_ model: WhisperModel) -> Bool {
        downloadProgress[model.id] != nil
    }

    /// Path for the active model. Nil means no model available at all. The legacy
    /// whisper.cpp checkout is never consulted here -- seedFromLegacyIfNeeded()
    /// (gated behind SUSURRO_DEV_SEED_LEGACY_MODEL) is the single, dev-only entry
    /// point for adopting it, so this stays a plain check of managed storage and
    /// behaves identically to a fresh install when that flag isn't set.
    public func activeModelPath() -> String? {
        guard let model = Self.catalog.first(where: { $0.id == activeModelID }),
              isDownloaded(model) else { return nil }
        return path(for: model).path
    }

    public func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: path(for: model))
    }

    public func download(_ model: WhisperModel) async throws {
        guard !isDownloading(model), !isDownloaded(model) else { return }
        guard let url = URL(string: Self.baseURL + model.fileName) else { return }

        downloadProgress[model.id] = 0
        defer { downloadProgress[model.id] = nil }

        let downloader = FileDownloader()
        let modelID = model.id
        let temporary = try await downloader.download(from: url) { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.downloadProgress[modelID] != nil else { return }
                self.downloadProgress[modelID] = fraction
                self.onProgress?(modelID, fraction)
            }
        }

        let destination = path(for: model)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        NSLog("[susurro] model %@ downloaded", model.id)
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
