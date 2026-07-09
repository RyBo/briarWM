import Foundation
import CoreGraphics

/// Mirrors `CGWindowID`, following the DisplayID/SpaceID convention in BSPNode.swift.
/// Persisted layouts key on this (not `WinID`, which is a per-session registry counter).
typealias WindowServerID = UInt32

/// On-disk record of every tree's shape, one file per save. Pure/`Codable` so it
/// carries no AX/CGS state — the WM converts window-server ids ⇄ `WinID` at the edges.
struct LayoutSnapshot: Codable {
    var savedAt: Date
    var bootTime: Date              // kern.boottime at save; mismatch on load ⇒ stale
    var trees: [TreeSnapshot]
}

struct TreeSnapshot: Codable {
    var space: SpaceID
    var display: DisplayID
    var focused: WindowServerID?
    var layoutPreset: String?       // LayoutPreset raw value so `cycle layout` resumes
    var root: NodeSnapshot?
}

/// `Codable` mirror of `BSPNode.Kind`. Value type (no parent links) since the shape
/// is all that persists; `TreeSnapshotCodec.rebuild` re-wires parents on the way back.
indirect enum NodeSnapshot: Codable {
    case leaf(WindowServerID)
    case split(orientation: Orientation, ratio: Double, first: NodeSnapshot, second: NodeSnapshot)
}

/// Bridges the live `BSPNode` tree to its `Codable` mirror. Closure-based so the pure
/// layer never sees AX/CGS: the caller supplies the `WinID` ⇄ `WindowServerID` mapping.
enum TreeSnapshotCodec {
    /// Encode a live subtree. Leaves whose WinID doesn't resolve to a window-server id
    /// are pruned; single-child splits collapse. nil when nothing survives.
    static func encode(_ node: BSPNode, id: (WinID) -> WindowServerID?) -> NodeSnapshot? {
        switch node.kind {
        case .leaf(let win):
            return id(win).map { .leaf($0) }
        case .split(let o, let r, let a, let b):
            let ea = encode(a, id: id)
            let eb = encode(b, id: id)
            switch (ea, eb) {
            case let (x?, y?): return .split(orientation: o, ratio: r, first: x, second: y)
            case let (x?, nil): return x    // sole survivor collapses into the split's slot
            case let (nil, y?): return y
            case (nil, nil): return nil
            }
        }
    }

    /// Rebuild a live subtree. Leaves whose WindowServerID doesn't resolve to a live
    /// WinID are pruned; single-child splits collapse; parent pointers wired.
    /// nil when nothing survives.
    static func rebuild(_ snap: NodeSnapshot, resolve: (WindowServerID) -> WinID?) -> BSPNode? {
        switch snap {
        case .leaf(let wsid):
            return resolve(wsid).map { BSPNode(leaf: $0) }
        case .split(let o, let r, let first, let second):
            let a = rebuild(first, resolve: resolve)
            let b = rebuild(second, resolve: resolve)
            switch (a, b) {
            // `init(split:)` wires `parent` on both children.
            case let (x?, y?): return BSPNode(split: o, ratio: r, first: x, second: y)
            case let (x?, nil): return x
            case let (nil, y?): return y
            case (nil, nil): return nil
            }
        }
    }
}
