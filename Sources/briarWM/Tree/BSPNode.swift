import CoreGraphics

/// Stable identifier for a managed window. Assigned by `WindowRegistry`;
/// the pure tree/layout code only requires it to be Hashable.
struct WinID: Hashable, CustomStringConvertible {
    let rawValue: UInt
    init(_ rawValue: UInt) { self.rawValue = rawValue }
    var description: String { "win#\(rawValue)" }
}

/// Mirrors `CGDirectDisplayID` without forcing CoreGraphics on the pure core.
typealias DisplayID = UInt32

/// A macOS Space (desktop) identifier. Mirrors the private `CGSSpaceID` (64-bit)
/// without forcing CoreGraphics/SkyLight on the pure core. `0` is the sentinel for
/// "no Space info" (used as a per-display pseudo-Space when Space queries are
/// unavailable — see `SpacesManager`).
typealias SpaceID = UInt64

/// A node in a binary space-partitioning tree.
/// A class (not an `indirect enum`) with a `weak parent` so removal,
/// sibling promotion, and upward navigation are cheap.
final class BSPNode {
    enum Kind {
        case leaf(WinID)
        case split(orientation: Orientation, ratio: Double, first: BSPNode, second: BSPNode)
    }

    var kind: Kind
    weak var parent: BSPNode?

    init(leaf id: WinID, parent: BSPNode? = nil) {
        self.kind = .leaf(id)
        self.parent = parent
    }

    init(split orientation: Orientation, ratio: Double, first: BSPNode, second: BSPNode, parent: BSPNode? = nil) {
        self.kind = .split(orientation: orientation, ratio: ratio, first: first, second: second)
        self.parent = parent
        first.parent = self
        second.parent = self
    }
}

extension BSPNode {
    var isLeaf: Bool {
        if case .leaf = kind { return true }
        return false
    }

    var windowID: WinID? {
        if case .leaf(let id) = kind { return id }
        return nil
    }

    /// All window IDs in this subtree, left-to-right (in-order).
    func leafWindowIDs() -> [WinID] {
        switch kind {
        case .leaf(let id):
            return [id]
        case .split(_, _, let a, let b):
            return a.leafWindowIDs() + b.leafWindowIDs()
        }
    }

    /// The leaf node holding `id`, if present in this subtree.
    func findLeaf(_ id: WinID) -> BSPNode? {
        switch kind {
        case .leaf(let wid):
            return wid == id ? self : nil
        case .split(_, _, let a, let b):
            return a.findLeaf(id) ?? b.findLeaf(id)
        }
    }

    func leftmostLeaf() -> BSPNode {
        switch kind {
        case .leaf: return self
        case .split(_, _, let a, _): return a.leftmostLeaf()
        }
    }

    func rightmostLeaf() -> BSPNode {
        switch kind {
        case .leaf: return self
        case .split(_, _, _, let b): return b.rightmostLeaf()
        }
    }

    /// Deep copy of this subtree containing only leaves where `keep` is true;
    /// single-child splits collapse to the surviving child. nil if no leaf survives.
    func pruned(keeping keep: (WinID) -> Bool) -> BSPNode? {
        switch kind {
        case .leaf(let id):
            return keep(id) ? BSPNode(leaf: id) : nil
        case .split(let o, let r, let a, let b):
            let na = a.pruned(keeping: keep)
            let nb = b.pruned(keeping: keep)
            switch (na, nb) {
            // `init(split:)` wires `parent` on both children — remove/resize/replace need it.
            case let (x?, y?): return BSPNode(split: o, ratio: r, first: x, second: y)
            case let (x?, nil): return x    // sole survivor collapses into the split's slot
            case let (nil, y?): return y
            case (nil, nil): return nil
            }
        }
    }

    /// ASCII rendering for the debug "dump tree" action.
    func describe(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch kind {
        case .leaf(let id):
            return "\(pad)• \(id)"
        case .split(let o, let r, let a, let b):
            let head = "\(pad)\(o == .horizontal ? "H" : "V") split r=\(String(format: "%.2f", r))"
            return [head, a.describe(indent: indent + 1), b.describe(indent: indent + 1)].joined(separator: "\n")
        }
    }
}
