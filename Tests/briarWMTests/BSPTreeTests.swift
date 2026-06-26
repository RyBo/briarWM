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
        t.toggleSplitOrientation(of: WinID(2))
        guard case .split(let o, _, _, _)? = t.root?.kind else { Issue.record("expected split"); return }
        #expect(o == .vertical)
    }
}
