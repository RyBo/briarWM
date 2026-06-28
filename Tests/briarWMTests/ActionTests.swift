import Testing
@testable import briarWM

@Suite struct ActionTests {

    @Test func directions() {
        #expect(Action.parse("focus left") == .focus(.left))
        #expect(Action.parse("focus right") == .focus(.right))
        #expect(Action.parse("move up") == .move(.up))
        #expect(Action.parse("move down") == .move(.down))
    }

    @Test func resize() {
        #expect(Action.parse("resize right 40") == .resize(.right, 40))
        #expect(Action.parse("resize left") == .resize(.left, Action.defaultResizeStep))
    }

    @Test func splitAndPreselect() {
        #expect(Action.parse("preselect vertical") == .preselect(.vertical))
        #expect(Action.parse("preselect horizontal") == .preselect(.horizontal))
        #expect(Action.parse("split toggle") == .toggleSplit)
        #expect(Action.parse("toggle split") == .toggleSplit)
    }

    @Test func layoutPresets() {
        #expect(Action.parse("cycle layout") == .cycleLayout)
        #expect(Action.parse("layout cycle") == .cycleLayout)
        #expect(Action.parse("layout next") == .cycleLayout)
        #expect(Action.parse("layout tiled") == .setLayout(.tiled))
        #expect(Action.parse("layout main-vertical") == .setLayout(.mainVertical))
        #expect(Action.parse("layout mv") == .setLayout(.mainVertical))
        #expect(Action.parse("layout nonsense") == nil)
        #expect(Action.parse("cycle") == nil)
    }

    @Test func togglesAndModes() {
        #expect(Action.parse("toggle float") == .toggleFloat)
        #expect(Action.parse("focus mode toggle") == .focusModeToggle)
        #expect(Action.parse("mode resize") == .enterMode("resize"))
        #expect(Action.parse("mode default") == .exitMode)
    }

    @Test func workspaceSwitch() {
        #expect(Action.parse("workspace 3") == .workspace(3))
        #expect(Action.parse("desktop 1") == .workspace(1))
        #expect(Action.parse("workspace") == nil)
        #expect(Action.parse("workspace foo") == nil)
    }

    @Test func workspaceMove() {
        #expect(Action.parse("move workspace 2") == .moveToWorkspace(2))
        #expect(Action.parse("move to workspace 4") == .moveToWorkspace(4))
        #expect(Action.parse("move container to workspace 5") == .moveToWorkspace(5))
        // The directional form must still win — not be read as a workspace move.
        #expect(Action.parse("move left") == .move(.left))
        #expect(Action.parse("move right") == .move(.right))
    }

    @Test func simpleVerbs() {
        #expect(Action.parse("fullscreen") == .fullscreen)
        #expect(Action.parse("close") == .close)
        #expect(Action.parse("reload") == .reload)
        #expect(Action.parse("restart") == .restart)
        #expect(Action.parse("balance") == .balance)
    }

    @Test func execPreservesCase() {
        #expect(Action.parse("exec Ghostty") == .exec("Ghostty"))
        #expect(Action.parse("exec open -a Raycast") == .exec("open -a Raycast"))
        #expect(Action.parse("exec") == nil)
    }

    @Test func unknownReturnsNil() {
        #expect(Action.parse("garbage zzz") == nil)
        #expect(Action.parse("focus sideways") == nil)
    }
}
