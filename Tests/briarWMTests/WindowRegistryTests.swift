import Testing
import ApplicationServices
@testable import briarWM

/// `rebind` underpins tab-aware tiling: a native tab coming to the front takes over the
/// existing leaf's WinID. Two app elements with distinct pids are CFEqual-distinct and need
/// no AX permission to create, so this runs in CI.
@Suite struct WindowRegistryTests {

    @Test func rebindKeepsWinIDAndState() {
        let reg = WindowRegistry()
        let elA = AXUIElementCreateApplication(getpid())
        let elB = AXUIElementCreateApplication(1)            // launchd — distinct element
        let id = reg.register(AXWindow(element: elA, pid: 42))
        reg.setFloating(id, true)
        #expect(reg.id(for: elA) == id)

        #expect(reg.rebind(id, to: elB, pid: 42))
        #expect(reg.id(for: elA) == nil)                     // old element unmapped
        #expect(reg.id(for: elB) == id)                      // new element → same WinID
        #expect(CFEqual(reg.window(for: id)!.element, elB))  // tracked element swapped
        #expect(reg.isFloating(id))                          // floating flag preserved
        #expect(reg.register(AXWindow(element: elB, pid: 42)) == id)  // no new WinID minted
    }

    @Test func rebindUnknownIDFails() {
        let reg = WindowRegistry()
        #expect(!reg.rebind(WinID(999), to: AXUIElementCreateApplication(getpid()), pid: 1))
    }
}
