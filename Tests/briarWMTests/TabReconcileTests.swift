import Testing
import Foundation
@testable import briarWM

/// Pure decision functions behind tab-aware adoption. The AX resolution that feeds them
/// (frame match against live tiles + the app's focused window) is verified live against
/// real Ghostty windows.
@Suite struct TabReconcileTests {

    @Test func tabDecisionCases() {
        // Not stacked on any tile → a standalone/first window.
        #expect(tabDecision(frameMatch: nil, isFront: true, leafAlreadyUsed: false) == .adopt)
        #expect(tabDecision(frameMatch: nil, isFront: false, leafAlreadyUsed: false) == .adopt)
        // Stacked on a tile → a native tab: front takes over the leaf, background tab is skipped.
        #expect(tabDecision(frameMatch: WinID(3), isFront: true, leafAlreadyUsed: false) == .rebind(WinID(3)))
        #expect(tabDecision(frameMatch: WinID(3), isFront: false, leafAlreadyUsed: false) == .ignore)
        // Front tab but its leaf was already claimed this pass → ignore (don't double-rebind).
        #expect(tabDecision(frameMatch: WinID(3), isFront: true, leafAlreadyUsed: true) == .ignore)
    }

    private func r(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 100, height: 100) }

    @Test func nearestStackedMatchesWithinTolerance() {
        let leaves: [(id: WinID, frame: CGRect?)] = [
            (WinID(1), r(0, 0)), (WinID(2), r(500, 0)), (WinID(3), r(1000, 0)),
        ]
        // A window stacked (≈ same frame) on leaf 2's tile.
        #expect(nearestStackedLeaf(r(505, 3), among: leaves, tolerance: 10) == WinID(2))
        #expect(nearestStackedLeaf(r(2, 1), among: leaves, tolerance: 10) == WinID(1))
    }

    @Test func nearestStackedRejectsDistantAndNil() {
        let leaves: [(id: WinID, frame: CGRect?)] = [(WinID(1), r(0, 0)), (WinID(2), r(500, 0))]
        #expect(nearestStackedLeaf(r(250, 0), among: leaves, tolerance: 10) == nil) // between tiles → not stacked
        #expect(nearestStackedLeaf(nil, among: leaves, tolerance: 10) == nil)        // nil candidate
        #expect(nearestStackedLeaf(r(0, 0), among: [], tolerance: 10) == nil)        // no leaves
        let nilFrame: [(id: WinID, frame: CGRect?)] = [(WinID(7), nil)]
        #expect(nearestStackedLeaf(r(0, 0), among: nilFrame, tolerance: 10) == nil)  // leaf without a frame
    }

    @Test func nearestStackedPicksClosestAmongOverlaps() {
        // Two leaves both near the candidate → the nearer center wins.
        let leaves: [(id: WinID, frame: CGRect?)] = [(WinID(1), r(0, 0)), (WinID(2), r(10, 0))]
        #expect(nearestStackedLeaf(r(9, 0), among: leaves, tolerance: 10) == WinID(2))
        #expect(nearestStackedLeaf(r(1, 0), among: leaves, tolerance: 10) == WinID(1))
    }
}
