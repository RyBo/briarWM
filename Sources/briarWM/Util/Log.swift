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
        h.seekToEndOfFile()
        self.handle = h
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        let ts = Self.formatter.string(from: Date())
        let extra = (metadata ?? [:]).merging(self.metadata) { a, _ in a }
        let suffix = extra.isEmpty ? "" : " " + extra.map { "\($0)=\($1)" }.joined(separator: " ")
        let text = "\(ts) [\(level)] \(message)\(suffix)\n"
        if let data = text.data(using: .utf8) {
            handle.write(data)
        }
    }
}
