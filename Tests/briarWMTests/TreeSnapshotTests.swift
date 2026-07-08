import Testing
import Foundation
@testable import briarWM

@Suite struct TreeSnapshotTests {

    /// Round-trip identity mapping: WinID(n) ⇄ WindowServerID(n).
    private func wsid(_ w: WinID) -> WindowServerID? { WindowServerID(w.rawValue) }
    private func winID(_ s: WindowServerID) -> WinID? { WinID(UInt(s)) }

    private func threeWindowTree() -> BSPNode {
        let inner = BSPNode(split: .vertical, ratio: 0.3, first: BSPNode(leaf: WinID(2)), second: BSPNode(leaf: WinID(3)))
        return BSPNode(split: .horizontal, ratio: 0.7, first: BSPNode(leaf: WinID(1)), second: inner)
    }

    @Test func encodeRebuildRoundTripPreservesShape() {
        let live = threeWindowTree()
        guard let snap = TreeSnapshotCodec.encode(live, id: wsid) else { Issue.record("expected snapshot"); return }
        guard let rebuilt = TreeSnapshotCodec.rebuild(snap, resolve: winID) else { Issue.record("expected rebuild"); return }
        // describe() captures orientation, ratio (2dp) and leaf order — the whole shape.
        #expect(rebuilt.describe() == live.describe())
        #expect(rebuilt.leafWindowIDs() == [WinID(1), WinID(2), WinID(3)])
    }

    @Test func rebuiltTreeHasParentLinks() {
        let snap = TreeSnapshotCodec.encode(threeWindowTree(), id: wsid)!
        let t = BSPTree(display: 1)
        t.root = TreeSnapshotCodec.rebuild(snap, resolve: winID)
        t.focused = WinID(2)
        t.remove(WinID(3))   // needs parent links to promote the sibling
        #expect(t.root!.leafWindowIDs() == [WinID(1), WinID(2)])
    }

    @Test func encodePrunesUnresolvableLeavesAndCollapses() {
        // win3 has no window-server id → inner V split collapses to leaf2.
        let snap = TreeSnapshotCodec.encode(threeWindowTree()) { $0 == WinID(3) ? nil : WindowServerID($0.rawValue) }
        guard case .split(let o, let r, let first, let second)? = snap else { Issue.record("expected split"); return }
        #expect(o == .horizontal)
        #expect(abs(r - 0.7) < 1e-9)
        guard case .leaf(let a) = first, case .leaf(let b) = second else { Issue.record("expected two leaves"); return }
        #expect(a == 1)
        #expect(b == 2)
    }

    @Test func encodeAllUnresolvableIsNil() {
        #expect(TreeSnapshotCodec.encode(threeWindowTree()) { _ in nil } == nil)
    }

    @Test func rebuildDeadIdsCollapseNestedChain() {
        // Snapshot of three windows; on rebuild only win1 is live → collapse to a leaf.
        let snap = TreeSnapshotCodec.encode(threeWindowTree(), id: wsid)!
        let rebuilt = TreeSnapshotCodec.rebuild(snap) { $0 == 1 ? WinID(1) : nil }
        #expect(rebuilt?.isLeaf == true)
        #expect(rebuilt?.windowID == WinID(1))
    }

    @Test func rebuildAllDeadIsNil() {
        let snap = TreeSnapshotCodec.encode(threeWindowTree(), id: wsid)!
        #expect(TreeSnapshotCodec.rebuild(snap) { _ in nil } == nil)
    }

    @Test func layoutSnapshotJSONRoundTrip() throws {
        let root = TreeSnapshotCodec.encode(threeWindowTree(), id: wsid)!
        let tree = TreeSnapshot(space: 42, display: 3, focused: 2,
                                layoutPreset: LayoutPreset.mainVertical.rawValue, root: root)
        let snapshot = LayoutSnapshot(savedAt: Date(timeIntervalSince1970: 1_000_000),
                                      bootTime: Date(timeIntervalSince1970: 999_000),
                                      trees: [tree])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: data)

        #expect(decoded.savedAt == snapshot.savedAt)
        #expect(decoded.bootTime == snapshot.bootTime)
        #expect(decoded.trees.count == 1)
        let dt = decoded.trees[0]
        #expect(dt.space == 42)
        #expect(dt.display == 3)
        #expect(dt.focused == 2)
        #expect(dt.layoutPreset == "main-vertical")
        // Rebuild the decoded tree and confirm it matches the original shape.
        let rebuilt = TreeSnapshotCodec.rebuild(dt.root!, resolve: winID)!
        #expect(rebuilt.describe() == threeWindowTree().describe())
    }
}
