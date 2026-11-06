import Foundation
import SusurroCore

/// Per-app coverage log for the text-handling stage (BEA-648). Since R7
/// (BEA-683) every dictation's structured record also goes to the unified
/// log (`Log.dictation`); this file is kept because docs/TEXT_HANDLING_FINDINGS.md
/// and docs/HANDSFREE_JOINS.md read coverage from it, and it outlives the
/// unified log's retention. Each line is a `DictationRecord.line` for a
/// dictation that reached the insert step: app, context source, AX read
/// path with lengths/positions only — never field or transcript text.
enum TextHandlingLog {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Susurro/text-handling.log")

    static let maxBytes = 1_000_000

    static func record(_ record: DictationRecord) {
        let line = record.line
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep it bounded: past 1 MB, the current file becomes .1 (replacing
        // any older one) and a fresh file starts.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
