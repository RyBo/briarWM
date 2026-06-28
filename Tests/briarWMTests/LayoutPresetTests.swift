import Testing
import Foundation
@testable import briarWM

/// Frames are asserted at `innerGap: 0` so equal-pane ratios (1/N, 1/(N-1), …) come
/// out exactly — gaps would spread a few px across the split chain (see LayoutPreset).
@Suite struct LayoutPresetTests {

    private let area = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func frames(_ preset: LayoutPreset, _ ids: [WinID], mainRatio: Double = 0.6) -> [WinID: CGRect] {
        LayoutEngine.computeFrames(root: preset.build(ids, mainRatio: mainRatio), area: area, innerGap: 0)
    }

    @Test func evenHorizontalEqualColumns() {
        let f = frames(.evenHorizontal, [1, 2, 3].map(WinID.init))
        // ~1px tolerance: each split rounds independently, so panes are 333/334/333.
        for id in 1...3 { #expect(approx(f[WinID(UInt(id))]!.width, 1000.0 / 3, 1.0)) }
        #expect(approx(f[WinID(1)]!.minX, 0))
        #expect(approx(f[WinID(2)]!.minX, 1000.0 / 3, 1.0))
        #expect(approx(f[WinID(3)]!.maxX, 1000))     // fills right edge
        for id in 1...3 { #expect(approx(f[WinID(UInt(id))]!.height, 800)) }
    }

    @Test func evenVerticalEqualRows() {
        let f = frames(.evenVertical, [1, 2, 3].map(WinID.init))
        for id in 1...3 { #expect(approx(f[WinID(UInt(id))]!.height, 800.0 / 3, 1.0)) }
        #expect(approx(f[WinID(1)]!.minY, 0))
        #expect(approx(f[WinID(3)]!.maxY, 800))      // fills bottom edge
        for id in 1...3 { #expect(approx(f[WinID(UInt(id))]!.width, 1000)) }
    }

    @Test func mainVerticalMasterLeftStackRight() {
        let f = frames(.mainVertical, [1, 2, 3].map(WinID.init), mainRatio: 0.6)
        #expect(rectApprox(f[WinID(1)]!, CGRect(x: 0, y: 0, width: 600, height: 800)))
        #expect(rectApprox(f[WinID(2)]!, CGRect(x: 600, y: 0, width: 400, height: 400)))
        #expect(rectApprox(f[WinID(3)]!, CGRect(x: 600, y: 400, width: 400, height: 400)))
    }

    @Test func mainHorizontalMasterTopRowBelow() {
        let f = frames(.mainHorizontal, [1, 2, 3].map(WinID.init), mainRatio: 0.6)
        #expect(rectApprox(f[WinID(1)]!, CGRect(x: 0, y: 0, width: 1000, height: 480)))
        #expect(rectApprox(f[WinID(2)]!, CGRect(x: 0, y: 480, width: 500, height: 320)))
        #expect(rectApprox(f[WinID(3)]!, CGRect(x: 500, y: 480, width: 500, height: 320)))
    }

    @Test func tiledFourMakesTwoByTwo() {
        let f = frames(.tiled, [1, 2, 3, 4].map(WinID.init))
        #expect(rectApprox(f[WinID(1)]!, CGRect(x: 0, y: 0, width: 500, height: 400)))
        #expect(rectApprox(f[WinID(2)]!, CGRect(x: 500, y: 0, width: 500, height: 400)))
        #expect(rectApprox(f[WinID(3)]!, CGRect(x: 0, y: 400, width: 500, height: 400)))
        #expect(rectApprox(f[WinID(4)]!, CGRect(x: 500, y: 400, width: 500, height: 400)))
    }

    @Test func orderIsInvariantAcrossPresets() {
        let ids = [1, 2, 3, 4].map(WinID.init)
        for preset in LayoutPreset.allCases {
            #expect(preset.build(ids)?.leafWindowIDs() == ids)
        }
    }

    @Test func edgeCases() {
        #expect(LayoutPreset.tiled.build([]) == nil)
        let one = LayoutPreset.mainVertical.build([WinID(7)])
        #expect(one?.isLeaf == true)
        #expect(one?.windowID == WinID(7))
    }

    @Test func cycleWrapsAround() {
        let all = LayoutPreset.allCases
        #expect(LayoutPreset.next(after: .tiled, in: all) == .evenHorizontal)        // wrap
        #expect(LayoutPreset.next(after: nil, in: all) == all.first)                 // first press
        #expect(LayoutPreset.next(after: .evenHorizontal, in: all) == .evenVertical) // step
        // A preset not present in the cycle restarts at the first entry.
        let cycle: [LayoutPreset] = [.evenHorizontal, .evenVertical]
        #expect(LayoutPreset.next(after: .tiled, in: cycle) == .evenHorizontal)
        #expect(LayoutPreset.next(after: .evenHorizontal, in: []) == nil)            // empty cycle
    }

    @Test func tokenParsing() {
        #expect(LayoutPreset(token: "mv") == .mainVertical)
        #expect(LayoutPreset(token: "even-h") == .evenHorizontal)
        #expect(LayoutPreset(token: "GRID") == .tiled)
        #expect(LayoutPreset(token: "nonsense") == nil)
    }

    @Test func applyPresetKeepsWindowsAndFocus() {
        let t = BSPTree(display: 1)
        t.insert(WinID(1))
        t.insert(WinID(2), focusedFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        t.insert(WinID(3), focusedFrame: CGRect(x: 500, y: 0, width: 500, height: 800))
        let before = t.windowIDs.sorted { $0.rawValue < $1.rawValue }
        let focus = t.focused

        t.applyPreset(.evenVertical)
        #expect(t.layoutPreset == .evenVertical)
        #expect(t.windowIDs.sorted { $0.rawValue < $1.rawValue } == before)  // same window set
        #expect(t.focused == focus)                                          // focus preserved
    }
}
