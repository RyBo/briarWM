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

    @Test func togglesAndModes() {
        #expect(Action.parse("toggle float") == .toggleFloat)
        #expect(Action.parse("focus mode toggle") == .focusModeToggle)
        #expect(Action.parse("mode resize") == .enterMode("resize"))
        #expect(Action.parse("mode default") == .exitMode)
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
