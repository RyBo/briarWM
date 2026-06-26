import Testing
import Foundation
@testable import briarWM

@Suite struct LayoutEngineTests {

    @Test func singleWindowFillsArea() {
        let root = BSPNode(leaf: WinID(1))
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = LayoutEngine.computeFrames(root: root, area: area, innerGap: 10)
        #expect(f.count == 1)
        #expect(rectApprox(f[WinID(1)]!, area))
    }

    @Test func horizontalSplitExactFill() {
        let root = BSPNode(split: .horizontal, ratio: 0.5,
                           first: BSPNode(leaf: WinID(1)), second: BSPNode(leaf: WinID(2)))
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = LayoutEngine.computeFrames(root: root, area: area, innerGap: 10)
        #expect(rectApprox(f[WinID(1)]!, CGRect(x: 0, y: 0, width: 495, height: 800)))
        #expect(rectApprox(f[WinID(2)]!, CGRect(x: 505, y: 0, width: 495, height: 800)))
        #expect(approx(f[WinID(1)]!.maxX + 10, f[WinID(2)]!.minX))   // gap between siblings
        #expect(approx(f[WinID(2)]!.maxX, area.maxX))                // fills right edge exactly
    }

    @Test func nestedNoOverlapExactFill() {
        let bottom = BSPNode(split: .horizontal, ratio: 0.5,
                             first: BSPNode(leaf: WinID(2)), second: BSPNode(leaf: WinID(3)))
        let root = BSPNode(split: .vertical, ratio: 0.5, first: BSPNode(leaf: WinID(1)), second: bottom)
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = LayoutEngine.computeFrames(root: root, area: area, innerGap: 20)
        #expect(f.count == 3)
        #expect(approx(f[WinID(1)]!.height, 390))
        #expect(approx(f[WinID(2)]!.minY, 410))
        #expect(approx(f[WinID(2)]!.maxY, area.maxY))
        #expect(approx(f[WinID(3)]!.maxX, area.maxX))
        #expect(f[WinID(2)]!.maxX + 20 <= f[WinID(3)]!.minX + 0.5)   // no overlap
    }

    @Test func nonHalfRatio() {
        let root = BSPNode(split: .horizontal, ratio: 0.75,
                           first: BSPNode(leaf: WinID(1)), second: BSPNode(leaf: WinID(2)))
        let area = CGRect(x: 0, y: 0, width: 1010, height: 800)   // usable 1000, wA 750
        let f = LayoutEngine.computeFrames(root: root, area: area, innerGap: 10)
        #expect(approx(f[WinID(1)]!.width, 750))
        #expect(approx(f[WinID(2)]!.width, 250))
    }

    @Test func zeroGap() {
        let root = BSPNode(split: .horizontal, ratio: 0.5,
                           first: BSPNode(leaf: WinID(1)), second: BSPNode(leaf: WinID(2)))
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = LayoutEngine.computeFrames(root: root, area: area, innerGap: 0)
        #expect(approx(f[WinID(1)]!.maxX, f[WinID(2)]!.minX))
    }
}
