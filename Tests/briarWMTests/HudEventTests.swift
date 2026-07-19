import Testing
@testable import briarWM

@Suite struct HudEventTests {

    @Test func titlesCoverBothArms() {
        #expect(HudEvent.preselect(.horizontal).title == "Preselect: Horizontal")
        #expect(HudEvent.preselect(.vertical).title == "Preselect: Vertical")
        #expect(HudEvent.splitToggled(.horizontal).title == "Split: Horizontal")
        #expect(HudEvent.splitToggled(.vertical).title == "Split: Vertical")
        #expect(HudEvent.float(on: true).title == "Floating")
        #expect(HudEvent.float(on: false).title == "Tiled")
        #expect(HudEvent.zoom(on: true).title == "Zoomed")
        #expect(HudEvent.zoom(on: false).title == "Unzoomed")
        #expect(HudEvent.workspaceFloat(on: true).title == "Desktop: Floating")
        #expect(HudEvent.workspaceFloat(on: false).title == "Desktop: Tiled")
        #expect(HudEvent.focusMode(floating: true).title == "Focus: Floating")
        #expect(HudEvent.focusMode(floating: false).title == "Focus: Tiled")
        #expect(HudEvent.bindingMode("resize").title == "Resize mode")
    }

    @Test func symbolsCoverBothArms() {
        #expect(HudEvent.preselect(.horizontal).symbolName == "rectangle.split.2x1")
        #expect(HudEvent.preselect(.vertical).symbolName == "rectangle.split.1x2")
        #expect(HudEvent.splitToggled(.horizontal).symbolName == "rectangle.split.2x1")
        #expect(HudEvent.splitToggled(.vertical).symbolName == "rectangle.split.1x2")
        #expect(HudEvent.float(on: true).symbolName == "macwindow.on.rectangle")
        #expect(HudEvent.float(on: false).symbolName == "rectangle.grid.2x2")
        #expect(HudEvent.zoom(on: true).symbolName == "arrow.up.left.and.arrow.down.right")
        #expect(HudEvent.zoom(on: false).symbolName == "arrow.down.right.and.arrow.up.left")
        #expect(HudEvent.workspaceFloat(on: true).symbolName == "rectangle.on.rectangle")
        #expect(HudEvent.focusMode(floating: true).symbolName == "macwindow.on.rectangle")
        #expect(HudEvent.focusMode(floating: false).symbolName == "rectangle.grid.2x2")
        #expect(HudEvent.bindingMode("resize").symbolName == "keyboard")
    }

    @Test func stickyStateSuffixComposesInOrder() {
        #expect(StickyState().suffix == "")
        #expect(StickyState(zoomed: true).suffix == "⛶")
        #expect(StickyState(focusedFloating: true).suffix == "~")
        #expect(StickyState(workspaceFloating: true).suffix == "≈")
        // All three on: zoom, then focused float, then workspace float — regardless of order.
        #expect(StickyState(zoomed: true, focusedFloating: true, workspaceFloating: true).suffix == "⛶~≈")
        #expect(StickyState(zoomed: true, workspaceFloating: true).suffix == "⛶≈")
    }
}
