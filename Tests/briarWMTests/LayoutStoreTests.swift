import Testing
import Foundation
@testable import briarWM

// Serialized: these mutate the shared `LayoutStore.baseDirectory`, so they must not run in
// parallel with each other. No other suite touches it.
@Suite(.serialized) struct LayoutStoreTests {

    /// Point `LayoutStore` at a throwaway directory for the duration of `body`.
    private func withTempStore(_ body: () throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("briarWM-layoutstore-\(UUID().uuidString)", isDirectory: true)
        let saved = LayoutStore.baseDirectory
        LayoutStore.baseDirectory = dir
        defer {
            LayoutStore.baseDirectory = saved
            try? FileManager.default.removeItem(at: dir)
        }
        try body()
    }

    private func sampleSnapshot() -> LayoutSnapshot {
        let root = NodeSnapshot.split(orientation: .horizontal, ratio: 0.6,
                                      first: .leaf(1), second: .leaf(2))
        let tree = TreeSnapshot(space: 7, display: 1, focused: 2,
                                layoutPreset: LayoutPreset.mainVertical.rawValue, root: root)
        return LayoutSnapshot(savedAt: Date(timeIntervalSince1970: 2_000_000),
                              bootTime: Date(timeIntervalSince1970: 1_999_000),
                              trees: [tree])
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withTempStore {
            let snap = sampleSnapshot()
            LayoutStore.save(snap)

            let loaded = try #require(LayoutStore.load())
            #expect(loaded.savedAt == snap.savedAt)
            #expect(loaded.bootTime == snap.bootTime)
            #expect(loaded.trees.count == 1)
            #expect(loaded.trees[0].space == 7)
            #expect(loaded.trees[0].focused == 2)
            #expect(loaded.trees[0].layoutPreset == "main-vertical")
            let rebuilt = try #require(TreeSnapshotCodec.rebuild(loaded.trees[0].root!) { WinID(UInt($0)) })
            #expect(rebuilt.leafWindowIDs() == [WinID(1), WinID(2)])
        }
    }

    @Test func loadMissingFileIsNil() throws {
        try withTempStore {
            #expect(LayoutStore.load() == nil)
        }
    }

    @Test func corruptFileLoadsNilAndIsDeleted() throws {
        try withTempStore {
            try FileManager.default.createDirectory(at: LayoutStore.baseDirectory, withIntermediateDirectories: true)
            try Data("{ not valid json".utf8).write(to: LayoutStore.fileURL)

            #expect(LayoutStore.load() == nil)
            #expect(!FileManager.default.fileExists(atPath: LayoutStore.fileURL.path))
        }
    }

    @Test func deleteRemovesFile() throws {
        try withTempStore {
            LayoutStore.save(sampleSnapshot())
            #expect(FileManager.default.fileExists(atPath: LayoutStore.fileURL.path))
            LayoutStore.delete()
            #expect(!FileManager.default.fileExists(atPath: LayoutStore.fileURL.path))
        }
    }

    @Test func currentBootTimeIsPlausible() {
        // Should resolve and be in the past (the machine booted before now).
        let boot = try? #require(LayoutStore.currentBootTime())
        if let boot { #expect(boot < Date()) }
    }
}
