import Foundation

/// Reads/writes the on-disk layout snapshot at `~/.local/state/briarWM/layout.json`.
/// Foundation-only — it never touches AX/CGS. The WindowManager builds the `LayoutSnapshot`
/// (converting window ids at the edges) and hands it here; this type just persists it.
///
/// Everything is best-effort: a failed save or a corrupt file must never crash the WM or
/// throw — persistence is a convenience, not a correctness requirement.
enum LayoutStore {
    /// The state directory the snapshot lives in. Mirrors `Log.logFileURL`'s convention.
    /// `var` (with a test seam in mind) so unit tests can redirect it to a temp dir; the
    /// `nonisolated(unsafe)` opt-out matches `Log.logger` — single-threaded on the main run
    /// loop, so no real races.
    nonisolated(unsafe) static var baseDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/briarWM", isDirectory: true)

    static var fileURL: URL { baseDirectory.appendingPathComponent("layout.json") }

    /// Atomically write the snapshot as JSON, creating the state dir if needed. Failures are
    /// logged and swallowed.
    static func save(_ snapshot: LayoutSnapshot) {
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            Log.logger.debug("saved layout: \(snapshot.trees.count) tree(s)")
        } catch {
            Log.logger.warning("layout save failed: \(error)")
        }
    }

    /// Decode the snapshot, or nil when the file is missing or corrupt. A corrupt file is
    /// deleted so it can't wedge every future startup.
    static func load() -> LayoutSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(LayoutSnapshot.self, from: data)
        } catch {
            Log.logger.warning("layout load failed (\(error)) — discarding \(fileURL.lastPathComponent)")
            delete()
            return nil
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The kernel's boot time, from `sysctl kern.boottime`. Persisted alongside a snapshot so
    /// a stale file from a previous boot (whose window-server ids no longer exist) is detected
    /// and ignored. nil if the sysctl fails.
    static func currentBootTime() -> Date? {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, u_int(mib.count), &tv, &size, nil, 0) == 0, tv.tv_sec != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
