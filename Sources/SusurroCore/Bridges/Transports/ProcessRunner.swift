import Foundation

/// Runs a command-line tool with a timeout, collecting stdout and stderr
/// separately (docs/BRIDGES.md). Blocking: call off the main thread.
/// Arguments are passed directly (no shell), so nothing is ever re-parsed.
/// Used by the Obsidian bridge; reusable for e.g. osascript.
public struct ProcessRunner: Sendable {
    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public init() {}

    /// nil = the tool is missing, failed to start, or timed out (killed).
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Output? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Drain both pipes on dedicated threads (not the shared GCD pool,
        // which a busy process can starve), so a chatty tool can't fill a
        // pipe buffer and deadlock against the wait below.
        let deadline = DispatchTime.now() + timeout
        let reads = DispatchGroup()
        nonisolated(unsafe) var outData = Data(), errData = Data()
        reads.enter(); reads.enter()
        Thread.detachNewThread { outData = out.fileHandleForReading.readDataToEndOfFile(); reads.leave() }
        Thread.detachNewThread { errData = err.fileHandleForReading.readDataToEndOfFile(); reads.leave() }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        // EOF follows the exit; never report a partial read as an answer.
        guard reads.wait(timeout: deadline + 1) == .success else { return nil }
        return Output(status: process.terminationStatus,
                      stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}
