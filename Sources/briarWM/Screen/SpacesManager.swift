import ApplicationServices
import CoreGraphics
import Foundation

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

/// The single place briarWM touches private CoreGraphics / SkyLight symbols.
///
/// macOS exposes no *public* API for which Space a window is on, for enumerating
/// Spaces, or for moving/switching Spaces. These live in SkyLight (re-exported from
/// CoreGraphics) and the Accessibility framework. They do **not** require disabling
/// SIP, but they are private and may drift between macOS releases — so every symbol
/// is resolved with `dlsym`, and `isAvailable` is false if any read-path symbol is
/// missing. Callers must degrade gracefully (briarWM falls back to one tree per
/// display, i.e. its pre-Spaces behavior) when `isAvailable == false`.
final class SpacesManager {

    // MARK: - Private symbol signatures (reverse-engineered; stable for ~a decade)

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias MoveWindowsToSpaceFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    private let cid: Int32
    private let getWindow: GetWindowFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let moveWindowsToSpace: MoveWindowsToSpaceFn?
    private let setCurrentSpaceFn: SetCurrentSpaceFn?

    /// `CGSCopySpacesForWindows` mask: current | other | user spaces (0x1 | 0x2 | 0x4).
    private static let allSpacesMask: Int32 = 0x7

    init() {
        // Resolve from the global scope first (these are usually already linked via
        // CoreGraphics); fall back to an explicit load of SkyLight.
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func sym(_ names: [String]) -> UnsafeMutableRawPointer? {
            let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
            for name in names {
                if let p = dlsym(rtldDefault, name) { return p }
                if let h = skyLight, let p = dlsym(h, name) { return p }
            }
            return nil
        }
        func cast<T>(_ p: UnsafeMutableRawPointer?, to _: T.Type) -> T? {
            p.map { unsafeBitCast($0, to: T.self) }
        }

        // SkyLight ships both CGS* and SLS* spellings; try both.
        let mainConn = cast(sym(["CGSMainConnectionID", "SLSMainConnectionID"]), to: MainConnectionFn.self)
        cid = mainConn?() ?? 0
        getWindow = cast(sym(["_AXUIElementGetWindow"]), to: GetWindowFn.self)
        copySpacesForWindows = cast(sym(["CGSCopySpacesForWindows", "SLSCopySpacesForWindows"]), to: CopySpacesForWindowsFn.self)
        copyManagedDisplaySpaces = cast(sym(["CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces"]), to: CopyManagedDisplaySpacesFn.self)
        moveWindowsToSpace = cast(sym(["CGSMoveWindowsToManagedSpace", "SLSMoveWindowsToManagedSpace"]), to: MoveWindowsToSpaceFn.self)
        setCurrentSpaceFn = cast(sym(["CGSManagedDisplaySetCurrentSpace", "SLSManagedDisplaySetCurrentSpace"]), to: SetCurrentSpaceFn.self)

        if !isAvailable {
            Log.logger.warning("Space awareness unavailable (private CGS symbols missing) — falling back to one tree per display")
        }
    }

    /// True when the *read* path (membership + layout) is usable. The move/switch
    /// commands degrade independently (they no-op if their symbol is missing).
    var isAvailable: Bool {
        cid != 0 && getWindow != nil && copySpacesForWindows != nil && copyManagedDisplaySpaces != nil
    }

    // MARK: - Reads

    /// The CGWindowID backing an AX window element (via private `_AXUIElementGetWindow`).
    func cgWindowID(for element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var wid = CGWindowID(0)
        return getWindow(element, &wid) == .success && wid != 0 ? wid : nil
    }

    /// The Space(s) a window belongs to. More than one ⇒ a sticky / all-Spaces window
    /// (callers treat those as floating). Empty if unknown.
    func spaceIDs(for windowID: CGWindowID) -> [SpaceID] {
        guard let copySpacesForWindows else { return [] }
        let windows = [NSNumber(value: windowID)] as CFArray
        guard let result = copySpacesForWindows(cid, Self.allSpacesMask, windows) else { return [] }
        let nums = (result.takeRetainedValue() as NSArray) as? [NSNumber] ?? []
        return nums.map { $0.uint64Value }
    }

    /// Ordered Space layout per display, with the currently-visible Space for each.
    func displayLayout() -> [DisplaySpaces] {
        guard let copyManagedDisplaySpaces, let unmanaged = copyManagedDisplaySpaces(cid) else { return [] }
        let displays = (unmanaged.takeRetainedValue() as NSArray) as? [[String: Any]] ?? []
        let uuidToID = displayIDByUUID()

        return displays.compactMap { dict -> DisplaySpaces? in
            guard let uuid = dict["Display Identifier"] as? String else { return nil }
            let spaceDicts = (dict["Spaces"] as? [[String: Any]]) ?? []
            let spaces = spaceDicts.compactMap { sd -> SpaceInfo? in
                guard let id = spaceID(from: sd) else { return nil }
                let type = (sd["type"] as? NSNumber)?.intValue ?? 0
                return SpaceInfo(id: id, type: type)
            }
            guard !spaces.isEmpty else { return nil }
            let current = (dict["Current Space"] as? [String: Any]).flatMap(spaceID(from:)) ?? spaces.first!.id
            // "Main" is the sentinel when "Displays have separate Spaces" is OFF.
            let displayID = uuid == "Main" ? DisplayID(CGMainDisplayID()) : uuidToID[uuid.uppercased()]
            return DisplaySpaces(displayUUID: uuid, displayID: displayID, currentSpace: current, spaces: spaces)
        }
    }

    // MARK: - Writes (commands)

    /// Send a window to another Space at the window-server level (no AX frame change,
    /// so it won't trip the snap-back feedback loop). No-op if the symbol is missing.
    func moveWindow(_ windowID: CGWindowID, toSpace space: SpaceID) {
        guard let moveWindowsToSpace else { return }
        moveWindowsToSpace(cid, [NSNumber(value: windowID)] as CFArray, space)
    }

    /// Switch the given display to `space`. May not animate and can be glitchy on some
    /// macOS versions; the resulting `activeSpaceDidChange` notification drives reconcile.
    func setCurrentSpace(_ space: SpaceID, onDisplayUUID uuid: String) {
        guard let setCurrentSpaceFn else { return }
        setCurrentSpaceFn(cid, uuid as CFString, space)
    }

    // MARK: - Helpers

    /// Read a Space ID from a space dict, preferring the 64-bit `id64` and falling back
    /// to `ManagedSpaceID`. Key spelling/width has varied across macOS releases.
    private func spaceID(from dict: [String: Any]) -> SpaceID? {
        if let n = dict["id64"] as? NSNumber { return n.uint64Value }
        if let n = dict["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        return nil
    }

    /// Map window-server display UUID strings → CGDirectDisplayID using the public
    /// `CGDisplayCreateUUIDFromDisplayID`.
    private func displayIDByUUID() -> [String: DisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }

        var map: [String: DisplayID] = [:]
        for id in ids {
            guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let cfStr = CFUUIDCreateString(nil, cfUUID) else { continue }
            map[(cfStr as String).uppercased()] = DisplayID(id)
        }
        return map
    }
}
