import Foundation

/// Pure decisions for display add/remove events (monitor sleep, unplug, dock changes).
/// Kept free of AppKit/CoreGraphics so the parking/restoration logic is unit-testable
/// (see `Tests/briarWMTests/DisplayReconfigTests.swift`).
enum DisplayReconfig {

    /// Where a *parked* tree should be restored, or `nil` to keep it parked.
    ///
    /// A tree is parked when its display disappears; its window structure is preserved so the
    /// layout can be rebuilt when the monitor returns. Restoration prefers the display that
    /// currently *owns the tree's Space*: the managed `SpaceID` survives a reconnect even when
    /// the `CGDirectDisplayID` is reassigned, so it's the stable key. It falls back to the
    /// tree's original display id (handles the pseudo-Space mode where Space queries are
    /// unavailable and `spaceOwner` is empty). Returns `nil` when neither resolves to a
    /// connected display — the monitor is still gone, so stay parked.
    static func restoreDisplay(space: SpaceID,
                               originalDisplay: DisplayID,
                               valid: Set<DisplayID>,
                               spaceOwner: [SpaceID: DisplayID]) -> DisplayID? {
        if let owner = spaceOwner[space], valid.contains(owner) { return owner }
        if valid.contains(originalDisplay) { return originalDisplay }
        return nil
    }
}
