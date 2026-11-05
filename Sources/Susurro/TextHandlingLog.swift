import Foundation

/// Per-app coverage log for the text-handling stage (BEA-648). macOS's
/// unified log does not keep Susurro's NSLog lines, so coverage is appended
/// to ~/Library/Logs/Susurro/text-handling.log. Lines carry the app, the
/// context source and the AX read path with lengths/positions only — never
/// field or transcript text.
enum TextHandlingLog {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Susurro/text-handling.log")

    static func record(_ line: String) {
        slog("ptt: context \(line)")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
