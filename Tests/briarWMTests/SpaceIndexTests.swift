import Testing
@testable import briarWM

/// `userSpaceID(at:in:)` is the only pure piece of the Spaces layer: it maps a 1-based
/// `workspace N` index onto the Nth *user* desktop, skipping fullscreen/system Spaces.
@Suite struct SpaceIndexTests {

    // type 0 = user, 4 = fullscreen, 2 = system.
    private let layout = [
        SpaceInfo(id: 101, type: 0),   // desktop 1
        SpaceInfo(id: 202, type: 4),   // a fullscreen space — not addressable
        SpaceInfo(id: 303, type: 0),   // desktop 2
        SpaceInfo(id: 404, type: 0),   // desktop 3
    ]

    @Test func oneBasedAndSkipsNonUser() {
        #expect(userSpaceID(at: 1, in: layout) == 101)
        #expect(userSpaceID(at: 2, in: layout) == 303)   // skips the fullscreen space
        #expect(userSpaceID(at: 3, in: layout) == 404)
    }

    @Test func outOfRangeReturnsNil() {
        #expect(userSpaceID(at: 0, in: layout) == nil)
        #expect(userSpaceID(at: 4, in: layout) == nil)    // only 3 user desktops exist
        #expect(userSpaceID(at: -1, in: layout) == nil)
    }

    @Test func emptyReturnsNil() {
        #expect(userSpaceID(at: 1, in: []) == nil)
        #expect(userSpaceID(at: 1, in: [SpaceInfo(id: 9, type: 4)]) == nil)   // no user spaces
    }
}
