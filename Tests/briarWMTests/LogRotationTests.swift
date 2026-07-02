import Testing
import Foundation
@testable import briarWM

@Suite struct LogRotationTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("briarWM-logtest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func rollsWhenOverLimit() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("briarWM.log")
        try Data(count: 100).write(to: log)

        Log.rotateIfNeeded(at: log, limit: 50)

        let rolled = log.appendingPathExtension("1")
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: rolled.path))
    }

    @Test func keepsWhenUnderLimit() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("briarWM.log")
        try Data(count: 10).write(to: log)

        Log.rotateIfNeeded(at: log, limit: 50)

        #expect(FileManager.default.fileExists(atPath: log.path))
        #expect(!FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
    }

    @Test func replacesExistingRolledFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("briarWM.log")
        let rolled = log.appendingPathExtension("1")
        try Data("old".utf8).write(to: rolled)
        try Data(count: 100).write(to: log)

        Log.rotateIfNeeded(at: log, limit: 50)

        let rolledData = try Data(contentsOf: rolled)
        #expect(rolledData.count == 100)   // fresh log's contents, not "old"
    }
}
