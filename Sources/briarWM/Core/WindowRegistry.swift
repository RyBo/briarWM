import ApplicationServices
import CoreGraphics

/// Hashable key for an AXUIElement (CFEqual/CFHash), so elements can index a dictionary.
private struct AXElementKey: Hashable {
    let element: AXUIElement
    static func == (l: AXElementKey, r: AXElementKey) -> Bool { CFEqual(l.element, r.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Maps stable `WinID`s to live `AXWindow`s and tracks which windows float.
final class WindowRegistry {
    private var nextRaw: UInt = 1
    private var byID: [WinID: AXWindow] = [:]
    private var idByElement: [AXElementKey: WinID] = [:]
    private(set) var floating: Set<WinID> = []

    func id(for element: AXUIElement) -> WinID? {
        idByElement[AXElementKey(element: element)]
    }

    @discardableResult
    func register(_ window: AXWindow) -> WinID {
        let key = AXElementKey(element: window.element)
        if let existing = idByElement[key] { return existing }
        let id = WinID(nextRaw)
        nextRaw += 1
        byID[id] = window
        idByElement[key] = id
        return id
    }

    /// Re-point an existing `WinID` at a new AX element — used when a native tab comes to
    /// the front and should occupy the tab group's existing tile. Keeps the `WinID` (and
    /// thus its tree slot, desired frame, focus, and floating flag) and swaps only the
    /// tracked element, preserving the byID/idByElement 1:1 index. `newElement` must be
    /// unmanaged (callers guarantee it). Returns false if `id` is unknown.
    @discardableResult
    func rebind(_ id: WinID, to newElement: AXUIElement, pid: pid_t) -> Bool {
        guard let old = byID[id] else { return false }
        idByElement.removeValue(forKey: AXElementKey(element: old.element))
        let window = AXWindow(element: newElement, pid: pid)
        byID[id] = window
        idByElement[AXElementKey(element: newElement)] = id
        return true
    }

    func unregister(_ id: WinID) {
        if let w = byID[id] { idByElement.removeValue(forKey: AXElementKey(element: w.element)) }
        byID.removeValue(forKey: id)
        floating.remove(id)
    }

    func window(for id: WinID) -> AXWindow? { byID[id] }

    func setFloating(_ id: WinID, _ flag: Bool) {
        if flag { floating.insert(id) } else { floating.remove(id) }
    }
    func isFloating(_ id: WinID) -> Bool { floating.contains(id) }
}
