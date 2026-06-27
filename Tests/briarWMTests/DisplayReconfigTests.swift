import Testing
@testable import briarWM

/// `DisplayReconfig.restoreDisplay` is the pure decision behind parked-tree restoration:
/// when a monitor returns, where (if anywhere) does a tree parked by an earlier
/// disconnect get reinstated? Space identity is the stable key; the original display id
/// is the fallback for pseudo-Space mode.
@Suite struct DisplayReconfigTests {

    private let spaceA: SpaceID = 101
    private let dispMain: DisplayID = 1
    private let dispExternalOld: DisplayID = 7
    private let dispExternalNew: DisplayID = 9

    @Test func prefersSpaceOwnerEvenWhenDisplayIdChanged() {
        // Monitor reconnected with a new CGDirectDisplayID; the Space still maps to it.
        let restore = DisplayReconfig.restoreDisplay(
            space: spaceA, originalDisplay: dispExternalOld,
            valid: [dispMain, dispExternalNew],
            spaceOwner: [spaceA: dispExternalNew])
        #expect(restore == dispExternalNew)
    }

    @Test func fallsBackToOriginalDisplayWhenNoSpaceOwner() {
        // Pseudo-Space mode (Space queries unavailable): spaceOwner empty, original is back.
        let restore = DisplayReconfig.restoreDisplay(
            space: spaceA, originalDisplay: dispExternalOld,
            valid: [dispMain, dispExternalOld],
            spaceOwner: [:])
        #expect(restore == dispExternalOld)
    }

    @Test func staysParkedWhenDisplayStillGone() {
        // Neither the Space's owner nor the original display is currently connected.
        let restore = DisplayReconfig.restoreDisplay(
            space: spaceA, originalDisplay: dispExternalOld,
            valid: [dispMain],
            spaceOwner: [spaceA: dispExternalOld])
        #expect(restore == nil)
    }

    @Test func ignoresSpaceOwnerOnAnInvalidDisplayAndFallsBack() {
        // Space maps to a display that isn't connected, but the original display is back.
        let restore = DisplayReconfig.restoreDisplay(
            space: spaceA, originalDisplay: dispMain,
            valid: [dispMain],
            spaceOwner: [spaceA: dispExternalOld])
        #expect(restore == dispMain)
    }

    @Test func nilWhenSpaceOwnerInvalidAndOriginalInvalid() {
        let restore = DisplayReconfig.restoreDisplay(
            space: spaceA, originalDisplay: dispExternalOld,
            valid: [dispMain],
            spaceOwner: [spaceA: dispExternalNew])   // owner not connected, original not connected
        #expect(restore == nil)
    }
}
