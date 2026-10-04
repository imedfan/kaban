import Foundation
import os

/// Журнал заседания: файл и Console.app (subsystem `app.kaban.spikes`).
enum SpikeFileLog {
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: SpikeIdentity.subsystem, category: "session")

    static var directory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KabanSpikes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var sessionURL: URL {
        directory.appendingPathComponent("session.log")
    }

    static func append(_ category: String, _ message: String) {
        let line = "\(timestamp()) [\(category)] \(message)"
        logger.log("\(line, privacy: .public)")
        let data = Data((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        let url = sessionURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
