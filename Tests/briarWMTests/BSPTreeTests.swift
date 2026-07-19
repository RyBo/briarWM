import Testing
import Foundation
@testable import briarWM

@Suite struct BSPTreeTests {

    @Test func autoSplitLongerEdge() {
        let wide = BSPTree(display: 1)
        wide.insert(WinID(1))
        wide.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 400))
        guard case .split(let o, _, _, _)? = wide.root?.kind else { Issue.record("expected split"); return }
        #expect(o == .horizontal)

        let tall = BSPTree(display: 1)
        tall.insert(WinID(1))
        tall.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 400, height: 1000))
        guard case .split(let o2, _, _, _)? = tall.root?.kind else { Issue.record("expected split"); return }
        #expect(o2 == .vertical)
    }

    @Test func autoSplitHorizontalIgnoresAspect() {
        // A tall focused frame would pick .vertical by longer-edge; the explicit
        // .horizontal override must win regardless of the frame's aspect ratio.
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 400, height: 1000),
                 autoSplit: .horizontal)
        guard case .split(let o, _, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(o == .horizontal)
    }

    @Test func autoSplitVerticalIgnoresAspect() {
        // A wide focused frame would pick .horizontal by longer-edge; the explicit
        // .vertical override must win regardless.
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 400),
                 autoSplit: .vertical)
        guard case .split(let o, _, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(o == .vertical)
    }

    @Test func insertBeforePlacesNewWindowFirst() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                 insertAt: .before)
        #expect(t.root!.leafWindowIDs() == [WinID(2), WinID(1)])   // new window becomes first child
    }

    @Test func resizeSingleWindowIsNoOp() {
        // One window → root is a leaf, so there's no split on any axis to slide.
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        let frames: [WinID: CGRect] = [WinID(1): CGRect(x: 0, y: 0, width: 1000, height: 800)]
        t.resize(WinID(1), direction: .right, deltaPx: 100, frames: frames)
        #expect(t.root?.isLeaf == true)   // unchanged, no crash
    }

    @Test func describeRendersTree() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 400))   // H split
        let text = t.root!.describe()
        #expect(text.contains("H split"))
        #expect(text.contains("win#1"))
        #expect(text.contains("win#2"))
    }

    @Test func insertUsesConfiguredRatio() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 400), ratio: 0.7)
        guard case .split(_, let ratio, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(ratio == 0.7)   // the existing window keeps 70%, the new one gets 30%
    }

    @Test func preselectOverridesAndClears() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.preselect = .vertical
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 100))
        guard case .split(let o, _, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(o == .vertical)            // preselect wins over longer-edge
        #expect(t.preselect == nil)        // cleared after use
    }

    @Test func insertFocusesNewWindow() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        #expect(t.focused == WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(t.focused == WinID(2))
    }

    @Test func removePromotesSiblingAndRefocuses() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        t.insert(WinID(3), focusedFrame: CGRect(x: 500, y: 0, width: 500, height: 800))
        #expect(Set(t.windowIDs) == [WinID(1), WinID(2), WinID(3)])
        t.remove(WinID(3))
        #expect(Set(t.windowIDs) == [WinID(1), WinID(2)])
        #expect(t.focused == WinID(2))     // refocuses promoted sibling
    }

    @Test func removeLastEmptiesTree() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.remove(WinID(1))
        #expect(t.isEmpty)
        #expect(t.focused == nil)
    }

    @Test func directionalFocusGeometry() {
        // AX top-left coords: y increases downward.
        let frames: [WinID: CGRect] = [
            WinID(1): CGRect(x: 0, y: 0, width: 500, height: 800),
            WinID(2): CGRect(x: 500, y: 0, width: 500, height: 400),
            WinID(3): CGRect(x: 500, y: 400, width: 500, height: 400),
        ]
        let t = BSPTree(display: 1)
        #expect(t.adjacent(to: WinID(2), direction: .left, frames: frames) == WinID(1))
        #expect(t.adjacent(to: WinID(2), direction: .down, frames: frames) == WinID(3))
        #expect(t.adjacent(to: WinID(3), direction: .up, frames: frames) == WinID(2))
        #expect(t.adjacent(to: WinID(1), direction: .left, frames: frames) == nil)
    }

    @Test func swapReordersLeaves() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(t.root!.leafWindowIDs() == [WinID(1), WinID(2)])
        t.swap(WinID(1), WinID(2))
        #expect(t.root!.leafWindowIDs() == [WinID(2), WinID(1)])
    }

    @Test func resizeAdjustsRatioAndClamps() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let frames: [WinID: CGRect] = [
            WinID(1): CGRect(x: 0, y: 0, width: 495, height: 800),
            WinID(2): CGRect(x: 505, y: 0, width: 495, height: 800),
        ]
        // WinID(1) is the first child: growing it (resize right) raises the ratio.
        t.resize(WinID(1), direction: .right, deltaPx: 100, frames: frames)   // 0.5 -> 0.6 over 1000px
        guard case .split(_, let r, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(approx(CGFloat(r), 0.6, 0.01))
        t.resize(WinID(1), direction: .right, deltaPx: 100_000, frames: frames)
        guard case .split(_, let r2, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(r2 <= 0.95 + 1e-9)        // clamped
    }

    /// `direction` slides the shared divider that way regardless of which window is
    /// focused, so either window can move it both ways from itself — no need to switch
    /// focus to the neighbour. Right -> divider right (ratio up); left -> divider left
    /// (ratio down). For the left window that means right=expand / left=shrink; for the
    /// right window (flush to the screen on its right) right=shrink / left=expand.
    @Test func resizeIsRelativeAndSymmetric() {
        func freshTree() -> BSPTree {
            let t = BSPTree(display: 1)
            t.insert(WinID(1))
            t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            return t
        }
        // WinID(1) on the left, WinID(2) on the right of a 1000px-wide horizontal split.
        let frames: [WinID: CGRect] = [
            WinID(1): CGRect(x: 0, y: 0, width: 495, height: 800),
            WinID(2): CGRect(x: 505, y: 0, width: 495, height: 800),
        ]
        func ratio(_ t: BSPTree) -> CGFloat {
            guard case .split(_, let r, _, _)? = t.root?.kind else { Issue.record("expected split"); return -1 }
            return CGFloat(r)
        }

        // "right" lands on ratio 0.6 from EITHER window; "left" lands on 0.4 from either.
        for win in [WinID(1), WinID(2)] {
            let r = freshTree(); r.resize(win, direction: .right, deltaPx: 100, frames: frames)
            #expect(approx(ratio(r), 0.6, 0.01))   // divider slid right
            let l = freshTree(); l.resize(win, direction: .left, deltaPx: 100, frames: frames)
            #expect(approx(ratio(l), 0.4, 0.01))    // divider slid left
        }
    }

    @Test func balanceResetsRatios() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        if case .split(let o, _, let a, let b)? = t.root?.kind {
            t.root!.kind = .split(orientation: o, ratio: 0.8, first: a, second: b)
        }
        t.balance()
        guard case .split(_, let r, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(approx(CGFloat(r), 0.5))
    }

    @Test func toggleSplitOrientation() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 400))   // horizontal
        let result = t.toggleSplitOrientation(of: WinID(2))
        #expect(result == .vertical)   // reports the new orientation
        guard case .split(let o, _, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(o == .vertical)
    }

    @Test func toggleSplitOrientationOnLoneLeafReturnsNil() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        #expect(t.toggleSplitOrientation(of: WinID(1)) == nil)   // no parent split to flip
    }

    // MARK: - pruned(keeping:)

    /// H(0.7) split of leaf1 and V(0.3) split of leaf2,leaf3. Built by hand so the
    /// ratios/orientations under test aren't whatever `insert` happened to pick.
    private func threeWindowTree() -> BSPNode {
        let inner = BSPNode(split: .vertical, ratio: 0.3, first: BSPNode(leaf: WinID(2)), second: BSPNode(leaf: WinID(3)))
        return BSPNode(split: .horizontal, ratio: 0.7, first: BSPNode(leaf: WinID(1)), second: inner)
    }

    @Test func prunedKeepsRatiosAndOrientationsAndCollapses() {
        // Drop win3: inner V split collapses to leaf2; outer H(0.7) survives verbatim.
        let pruned = threeWindowTree().pruned { $0 != WinID(3) }
        guard case .split(let o, let r, let a, let b)? = pruned?.kind else { Issue.record("expected split"); return }
        #expect(o == .horizontal)
        #expect(approx(CGFloat(r), 0.7))
        #expect(a.windowID == WinID(1))
        #expect(b.windowID == WinID(2))   // inner split collapsed to its sole survivor
    }

    @Test func prunedCollapsesNestedSingleSurvivorToLeaf() {
        // Keep only win2: everything collapses down to a bare leaf.
        let pruned = threeWindowTree().pruned { $0 == WinID(2) }
        #expect(pruned?.isLeaf == true)
        #expect(pruned?.windowID == WinID(2))
    }

    @Test func prunedAllRemovedIsNil() {
        #expect(threeWindowTree().pruned { _ in false } == nil)
    }

    @Test func prunedWiresParentLinks() {
        // A pruned copy must be a functioning tree: remove() relies on parent links to
        // find and promote a sibling. If parents were left dangling this would no-op.
        let t = BSPTree(display: 1)
        t.root = threeWindowTree().pruned { _ in true }   // full deep copy
        t.focused = WinID(3)
        t.remove(WinID(2))
        #expect(t.root!.leafWindowIDs() == [WinID(1), WinID(3)])
        #expect(t.contains(WinID(3)))
    }

    // MARK: - removeAll

    @Test func removeAllPreservesSurvivorStructure() {
        // even-horizontal chain of 4; drop the two middle windows.
        let t = BSPTree(display: 1)
        t.root = LayoutPreset.evenHorizontal.build([1, 2, 3, 4].map(WinID.init))
        t.focused = WinID(1)
        t.removeAll([WinID(2), WinID(3)])
        #expect(t.root!.leafWindowIDs() == [WinID(1), WinID(4)])   // survivors keep order
    }

    @Test func removeAllRepairsFocusWhenRemoved() {
        let t = BSPTree(display: 1)
        t.root = LayoutPreset.evenHorizontal.build([1, 2, 3].map(WinID.init))
        t.focused = WinID(2)
        t.removeAll([WinID(2)])
        #expect(t.focused != nil)
        #expect(t.contains(t.focused!))
    }

    @Test func removeAllKeepsFocusWhenSurvivor() {
        let t = BSPTree(display: 1)
        t.root = LayoutPreset.evenHorizontal.build([1, 2, 3].map(WinID.init))
        t.focused = WinID(1)
        t.removeAll([WinID(3)])
        #expect(t.focused == WinID(1))   // untouched survivor stays focused
    }

    @Test func removeAllEmptiesTree() {
        let t = BSPTree(display: 1)
        t.root = LayoutPreset.evenHorizontal.build([1, 2].map(WinID.init))
        t.focused = WinID(1)
        t.removeAll([WinID(1), WinID(2)])
        #expect(t.isEmpty)
        #expect(t.focused == nil)
    }

    // MARK: - insertSubtree

    @Test func insertSubtreeIntoEmptyTreeBecomesRootVerbatim() {
        let t = BSPTree(display: 1)
        let sub = BSPNode(split: .vertical, ratio: 0.3, first: BSPNode(leaf: WinID(5)), second: BSPNode(leaf: WinID(6)))
        t.insertSubtree(sub)
        #expect(t.root === sub)                                // installed as-is
        #expect(t.root!.leafWindowIDs() == [WinID(5), WinID(6)])
        #expect(t.focused == WinID(5))                         // leftmost leaf
    }

    @Test func insertSubtreeSplitsFocusedLeaf() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        let sub = BSPNode(split: .vertical, ratio: 0.3, first: BSPNode(leaf: WinID(2)), second: BSPNode(leaf: WinID(3)))
        t.insertSubtree(sub, focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 400))  // H split
        #expect(t.root!.leafWindowIDs() == [WinID(1), WinID(2), WinID(3)])
        guard case .split(let o, _, let a, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(o == .horizontal)
        #expect(a.windowID == WinID(1))     // existing leaf first (insertAt .after)
        #expect(t.focused == WinID(2))      // subtree's leftmost leaf
    }

    @Test func insertSubtreeConsumesPreselect() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.preselect = .vertical
        let sub = BSPNode(split: .horizontal, ratio: 0.5, first: BSPNode(leaf: WinID(2)), second: BSPNode(leaf: WinID(3)))
        t.insertSubtree(sub, focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 100))  // would be H by longer-edge
        guard case .split(let o, _, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(o == .vertical)        // preselect wins
        #expect(t.preselect == nil)    // cleared
    }
}
