import Testing
import Foundation
@testable import briarWM

/// Pure-layer coverage for the `BSPTree` workspace-float primitives that back the
/// `toggle workspace float` command. The orchestration in `WindowManager` (floating the
/// live windows, best-effort survivor filtering) needs the AX runtime and isn't unit-tested.
@Suite struct WorkspaceFloatTests {

    private let wide = CGRect(x: 0, y: 0, width: 1000, height: 400)
    private let tall = CGRect(x: 0, y: 0, width: 400, height: 1000)

    /// A 3-window tree with a mixed split shape.
    private func threeWindowTree() -> BSPTree {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: wide)
        t.insert(WinID(3), focusedFrame: tall)
        return t
    }

    @Test func enterCapturesShapeAndEmptiesTree() {
        let t = threeWindowTree()
        let shape = t.root!.describe()
        let ids = t.enterWorkspaceFloat()
        #expect(Set(ids) == [WinID(1), WinID(2), WinID(3)])
        #expect(t.isEmpty)
        #expect(t.focused == nil)
        #expect(t.workspaceFloat != nil)
        #expect(t.workspaceFloat?.savedRoot?.describe() == shape)
        #expect(t.workspaceFloat?.floated == [WinID(1), WinID(2), WinID(3)])
    }

    @Test func enterOnEmptyTreeArmsMode() {
        let t = BSPTree(display: 1)
        let ids = t.enterWorkspaceFloat()
        #expect(ids.isEmpty)
        #expect(t.workspaceFloat != nil)       // armed: new windows will float
        #expect(t.workspaceFloat?.floated.isEmpty == true)
    }

    @Test func enterTwiceIsNoop() {
        let t = threeWindowTree()
        _ = t.enterWorkspaceFloat()
        let again = t.enterWorkspaceFloat()
        #expect(again.isEmpty)                  // already on: no windows to re-float
    }

    @Test func exitWithoutEnterIsNoop() {
        let t = threeWindowTree()
        let shape = t.root!.describe()
        t.exitWorkspaceFloat(returning: [WinID(1), WinID(2), WinID(3)])
        #expect(t.root!.describe() == shape)
        #expect(t.workspaceFloat == nil)
    }

    @Test func exitRestoresExactShape() {
        let t = threeWindowTree()
        t.focused = WinID(2)
        t.layoutPreset = .tiled
        let shape = t.root!.describe()
        let ids = t.enterWorkspaceFloat()
        t.exitWorkspaceFloat(returning: ids)
        #expect(t.root!.describe() == shape)
        #expect(t.focused == WinID(2))
        #expect(t.layoutPreset == .tiled)
        #expect(t.workspaceFloat == nil)
    }

    @Test func exitPrunesClosedWindows() {
        let t = threeWindowTree()
        t.focused = WinID(2)                    // will be pruned → focus must repair
        _ = t.enterWorkspaceFloat()
        t.exitWorkspaceFloat(returning: [WinID(1), WinID(3)])   // win 2 closed while floating
        #expect(Set(t.windowIDs) == [WinID(1), WinID(3)])
        #expect(!t.contains(WinID(2)))
        #expect(t.focused != nil)
        #expect(t.focused != WinID(2))          // repaired to a survivor
    }

    @Test func exitInsertsNewcomers() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: wide)
        t.focused = WinID(1)
        let ids = t.enterWorkspaceFloat()       // [1, 2]
        // A window opened while floating returns alongside the originals.
        t.exitWorkspaceFloat(returning: ids + [WinID(9)])
        #expect(t.contains(WinID(1)))
        #expect(t.contains(WinID(2)))
        #expect(t.contains(WinID(9)))
        #expect(t.root!.leafWindowIDs() == [WinID(1), WinID(2), WinID(9)])   // originals kept, newcomer appended
        #expect(t.focused == WinID(1))          // savedFocused wins
    }

    @Test func exitKeepsManuallyTiledWindow() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: wide)
        _ = t.enterWorkspaceFloat()
        // Simulate a manual unfloat during the mode: a window tiled back into the empty tree.
        t.insert(WinID(5))
        t.exitWorkspaceFloat(returning: [WinID(1), WinID(2)])
        #expect(t.contains(WinID(5)))           // must not be orphaned by the root swap
        #expect(t.contains(WinID(1)))
        #expect(t.contains(WinID(2)))
    }
}
