/// Canonical tmux-style preset arrangements. A preset rebuilds the *whole* tree
/// over the desktop's windows (in their current in-order traversal) into a fixed
/// shape, discarding any manual split/resize tweaks — the same spirit as `balance`.
///
/// PURE: knows nothing about AppKit/AX. Raw values double as config/parse tokens.
enum LayoutPreset: String, CaseIterable, Equatable {
    case evenHorizontal = "even-horizontal"   // all side-by-side
    case evenVertical   = "even-vertical"     // all stacked
    case mainVertical   = "main-vertical"     // one main pane left, rest stacked right
    case mainHorizontal = "main-horizontal"   // main pane top, rest side-by-side below
    case tiled          = "tiled"             // balanced grid

    /// Parse a config/binding token. Accepts the canonical name plus short aliases.
    init?(token: String) {
        switch token.lowercased() {
        case "even-horizontal", "even-h", "evenh", "eh": self = .evenHorizontal
        case "even-vertical",   "even-v", "evenv", "ev": self = .evenVertical
        case "main-vertical",   "main-v", "mainv", "mv": self = .mainVertical
        case "main-horizontal", "main-h", "mainh", "mh": self = .mainHorizontal
        case "tiled", "grid":                            self = .tiled
        default: return nil
        }
    }
}

extension LayoutPreset {
    /// Build a fresh BSP root over `ids` (kept in order). Returns nil for empty input.
    /// `mainRatio` is only consulted by the main-* presets. Every preset lays its
    /// children out in input order, so `leafWindowIDs()` of the result equals `ids` —
    /// that invariant is what makes cycling stable and reversible.
    func build(_ ids: [WinID], mainRatio: Double = 0.6) -> BSPNode? {
        guard ids.count > 1 else { return ids.first.map { BSPNode(leaf: $0) } }
        switch self {
        case .evenHorizontal: return Self.leafChain(ids, .horizontal)
        case .evenVertical:   return Self.leafChain(ids, .vertical)
        case .mainVertical:   return Self.main(ids, mainAxis: .horizontal, restAxis: .vertical, ratio: mainRatio)
        case .mainHorizontal: return Self.main(ids, mainAxis: .vertical,   restAxis: .horizontal, ratio: mainRatio)
        case .tiled:          return Self.tiled(ids)
        }
    }

    /// Equal-extent right-leaning chain. Ratios 1/N, 1/(N-1), … 1/2 make every pane
    /// the same size: the first child takes `extent/N`, the rest recurse over the
    /// remainder. (Exact at gap=0; gaps spread a few px across the chain.)
    private static func nodeChain(_ nodes: [BSPNode], _ o: Orientation) -> BSPNode {
        guard nodes.count > 1 else { return nodes[0] }
        return BSPNode(split: o, ratio: 1.0 / Double(nodes.count),
                       first: nodes[0],
                       second: nodeChain(Array(nodes.dropFirst()), o))
    }

    private static func leafChain(_ ids: [WinID], _ o: Orientation) -> BSPNode {
        nodeChain(ids.map { BSPNode(leaf: $0) }, o)
    }

    /// `ids[0]` is the main pane on one side at `ratio`; the rest fill the other side,
    /// equal-stacked along `restAxis`. Caller guarantees `ids.count >= 2`.
    private static func main(_ ids: [WinID], mainAxis: Orientation, restAxis: Orientation, ratio: Double) -> BSPNode {
        let mainLeaf = BSPNode(leaf: ids[0])
        let rest = leafChain(Array(ids.dropFirst()), restAxis)
        return BSPNode(split: mainAxis, ratio: ratio, first: mainLeaf, second: rest)
    }

    /// Balanced grid, row-major: `cols = ceil(√N)`, `rows = ceil(N/cols)`. Outer
    /// equal-height vertical chain of rows; each row an equal-width horizontal chain.
    /// A partial last row gets fewer, wider cells (tmux's "tiled").
    private static func tiled(_ ids: [WinID]) -> BSPNode {
        let n = ids.count
        let cols = Int(Double(n).squareRoot().rounded(.up))
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        var rowNodes: [BSPNode] = []
        for r in 0..<rows {
            let lo = r * cols
            let hi = min(n, lo + cols)
            rowNodes.append(leafChain(Array(ids[lo..<hi]), .horizontal))
        }
        return nodeChain(rowNodes, .vertical)
    }

    /// Next preset in `cycle`, wrapping around. A nil/unknown `current` (first press,
    /// or a preset the user removed from the cycle) starts at the first entry.
    static func next(after current: LayoutPreset?, in cycle: [LayoutPreset]) -> LayoutPreset? {
        guard let first = cycle.first else { return nil }
        guard let cur = current, let i = cycle.firstIndex(of: cur) else { return first }
        return cycle[(i + 1) % cycle.count]
    }
}
