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

    /// Number of leaves in this subtree.
    var leafCount: Int {
        switch kind {
        case .leaf: return 1
        case .split(_, _, let a, let b): return a.leafCount + b.leafCount
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
