import Foundation

/// Pure Space data model: the value types the window-server layer reports, plus the
/// pure queries over them. Kept free of `ApplicationServices` / private CGS so it stays
/// unit-testable (see SpaceIndexTests / ActiveSpaceTests). `SpacesManager` builds these
/// from the private symbols.

/// One managed Space (desktop) as reported by the window server.
///
/// `type` is the raw CGS space type: `0` = user (a normal, tileable desktop),
/// `4` = native fullscreen, `2` = system. Only `type == 0` Spaces are tiled and
/// addressable by the `workspace N` / `move workspace N` commands.
struct SpaceInfo: Equatable {
    let id: SpaceID
    let type: Int
    var isUser: Bool { type == 0 }
}

/// The Space layout of a single display: its ordered list of Spaces (left → right)
/// and which one is currently visible.
struct DisplaySpaces: Equatable {
    let displayUUID: String      // window-server display key; needed to switch Spaces
    let displayID: DisplayID?    // resolved CGDirectDisplayID, or nil if unmatched
    let currentSpace: SpaceID
    let spaces: [SpaceInfo]

    /// True when the currently-visible Space is a normal user desktop. While the screen
    /// is locked (or showing the login window), the window server reports a system Space
    /// as current — which is *not* one of our trees. Callers use this to avoid recording
    /// that transient Space as "active" and stranding tiling until something re-queries.
    /// Pure — unit-testable. False if the current Space isn't found in `spaces`.
    var currentIsUserSpace: Bool {
        spaces.first { $0.id == currentSpace }?.isUser ?? false
    }
}

/// 1-based index into the *user* Spaces of `spaces` (skipping fullscreen/system).
/// Pure — no window-server calls — so it is unit-testable. Returns nil when the
/// index is out of range. `workspace 1` maps to the leftmost user desktop.
func userSpaceID(at index: Int, in spaces: [SpaceInfo]) -> SpaceID? {
    let user = spaces.filter { $0.isUser }
    guard index >= 1, index <= user.count else { return nil }
    return user[index - 1].id
}
