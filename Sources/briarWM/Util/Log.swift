import Foundation
import Logging

/// Process-wide logger. Writes to stderr and to a single file at
/// `~/.local/state/briarWM/briarWM.log` so you can `tail -f` it while iterating.
enum Log {
    // Set once at startup, read everywhere on the main thread. The unsafe opt-out
    // is appropriate: it is assigned before the run loop starts and never mutated again.
    nonisolated(unsafe) private(set) static var logger = Logger(label: "briarWM")

    static var logFileURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/briarWM", isDirectory: true)
        return base.appendingPathComponent("briarWM.log")
    }

    static func bootstrap(level: Logger.Level = .info) {
        let fileURL = logFileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(at: fileURL)

        LoggingSystem.bootstrap { label in
            var handlers: [any LogHandler] = [StreamLogHandler.standardError(label: label)]
            if let fileHandler = FileLogHandler(label: label, fileURL: fileURL) {
                handlers.append(fileHandler)
            }
            return MultiplexLogHandler(handlers)
        }
        var l = Logger(label: "briarWM")
        l.logLevel = level
        logger = l
    }

    /// One-file rotation: if the log at `url` is larger than `limit` (default 5 MB),
    /// move it aside to `briarWM.log.1` (replacing any previous `.1`) and start fresh.
    /// Best-effort — any failure just leaves the existing log in place.
    static func rotateIfNeeded(at url: URL, limit: Int = 5 * 1024 * 1024) {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int, size > limit else { return }
        let rolled = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: url, to: rolled)
    }
}

/// Minimal append-only file LogHandler. Holds a `FileHandle` (a reference type),
/// so it's marked `@unchecked Sendable`; all writes happen serially on the main thread.
struct FileLogHandler: LogHandler, @unchecked Sendable {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    private let handle: FileHandle
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init?(label: String, fileURL: URL) {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? h.seekToEnd()
        self.handle = h
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let ts = Self.formatter.string(from: Date())
        let extra = (event.metadata ?? [:]).merging(self.metadata) { a, _ in a }
        let suffix = extra.isEmpty ? "" : " " + extra.map { "\($0)=\($1)" }.joined(separator: " ")
        let text = "\(ts) [\(event.level)] \(event.message)\(suffix)\n"
        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
