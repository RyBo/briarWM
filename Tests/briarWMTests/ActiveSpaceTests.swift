import Testing
@testable import briarWM

/// `DisplaySpaces.currentIsUserSpace` is the pure guard that keeps the loginwindow /
/// lock-screen Space from being recorded as a display's active Space. When it returns
/// false, `WindowManager.refreshActiveSpaces` leaves the last-known-good user desktop in
/// place so tiling resumes cleanly on unlock (`resync`) instead of stalling.
@Suite struct ActiveSpaceTests {

    // type 0 = user, 4 = fullscreen, 2 = system.
    private func display(current: SpaceID, _ spaces: [SpaceInfo]) -> DisplaySpaces {
        DisplaySpaces(displayUUID: "Main", displayID: 1, currentSpace: current, spaces: spaces)
    }

    @Test func currentUserDesktopIsUserSpace() {
        let ds = display(current: 101, [
            SpaceInfo(id: 101, type: 0),
            SpaceInfo(id: 303, type: 0),
        ])
        #expect(ds.currentIsUserSpace)
    }

    @Test func lockScreenSystemSpaceIsNotUserSpace() {
        // The loginwindow Space (system, type 2) is reported as current while locked.
        let ds = display(current: 999, [
            SpaceInfo(id: 101, type: 0),   // the real desktop, now hidden behind the lock
            SpaceInfo(id: 999, type: 2),   // loginwindow / lock screen
        ])
        #expect(!ds.currentIsUserSpace)
    }

    @Test func nativeFullscreenCurrentIsNotUserSpace() {
        let ds = display(current: 202, [
            SpaceInfo(id: 101, type: 0),
            SpaceInfo(id: 202, type: 4),   // a native-fullscreen Space is current
        ])
        #expect(!ds.currentIsUserSpace)
    }

    @Test func currentNotPresentIsNotUserSpace() {
        // If the current Space isn't even in the display's list, treat it as non-user
        // (don't overwrite the active Space with a value we can't classify).
        let ds = display(current: 555, [SpaceInfo(id: 101, type: 0)])
        #expect(!ds.currentIsUserSpace)
    }

    @Test func emptyDisplayIsNotUserSpace() {
        let ds = display(current: 101, [])
        #expect(!ds.currentIsUserSpace)
    }
}
