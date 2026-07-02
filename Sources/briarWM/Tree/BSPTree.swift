import CoreGraphics

enum InsertAt: String {
    case after, before
}

/// How the auto-split orientation is picked for a new insert (config `auto_split`),
/// when no bspwm-style preselection is set.
enum AutoSplit {
    /// Split along the focused window's longer edge (bspwm default).
    case longerEdge
    /// Always split horizontally (side-by-side).
    case horizontal
    /// Always split vertically (stacked).
    case vertical

    init?(token: String) {
        switch token.lowercased() {
        case "longer_edge": self = .longerEdge
        case "horizontal": self = .horizontal
        case "vertical": self = .vertical
        default: return nil
        }
    }
}

/// One BSP tree per display. Pure data structure + algorithms; knows nothing
/// about the Accessibility API. Geometry-dependent operations (focus/resize)
/// take a precomputed `frames` map so they stay testable.
final class BSPTree {
    /// The display this tree tiles. Mutable because a parked tree — one whose monitor slept
    /// or was unplugged — is re-pointed onto the display it returns on, whose
    /// CGDirectDisplayID may have been reassigned across the reconnection.
    var display: DisplayID
    /// The macOS Space (desktop) this tree tiles. Each Space belongs to exactly one
    /// display, so `(space)` uniquely identifies a tree. Defaults to `0` so existing
    /// callers/tests that only care about the display compile unchanged.
    let space: SpaceID
    var root: BSPNode?
    var focused: WinID?
    /// bspwm-style preselection: orientation to use for the *next* insert.
    var preselect: Orientation?
    /// The canonical preset this tree was last snapped to (via `cycle layout`), or
    /// nil if it's an organic BSP tree. Remembered per-Space so cycling advances from
    /// where it left off; goes stale once a window is inserted/removed, which is fine —
    /// the next cycle press just rebuilds from the first preset onward.
    var layoutPreset: LayoutPreset?

    init(display: DisplayID, space: SpaceID = 0) {
        self.display = display
        self.space = space
    }

    var isEmpty: Bool { root == nil }
    var windowIDs: [WinID] { root?.leafWindowIDs() ?? [] }
    func contains(_ id: WinID) -> Bool { root?.findLeaf(id) != nil }

    // MARK: - Insert

    /// Insert `win` by splitting the focused leaf (bspwm "automatic" mode).
    /// `focusedFrame` is the current rect of the focused window, used to pick the
    /// split orientation along its longer edge when no preselection is set.
    /// `ratio` is the new split's share for its first child (config `default_ratio`).
    func insert(_ win: WinID,
                focusedFrame: CGRect? = nil,
                insertAt: InsertAt = .after,
                autoSplit: AutoSplit = .longerEdge,
                ratio: Double = 0.5) {
        guard let root = root else {
            self.root = BSPNode(leaf: win)
            focused = win
            return
        }

        // `findLeaf`/`rightmostLeaf` return leaves, so `windowID` below is always non-nil.
        let target = focused.flatMap { root.findLeaf($0) } ?? root.rightmostLeaf()
        guard let oldWin = target.windowID else { return }

        let orientation = preselect ?? autoOrientation(focusedFrame, autoSplit: autoSplit)
        preselect = nil

        let oldLeaf = BSPNode(leaf: oldWin)
        let newLeaf = BSPNode(leaf: win)
        let (first, second) = (insertAt == .after) ? (oldLeaf, newLeaf) : (newLeaf, oldLeaf)
        let split = BSPNode(split: orientation, ratio: ratio, first: first, second: second)
        replace(target, with: split)
        focused = win
    }

    private func autoOrientation(_ frame: CGRect?, autoSplit: AutoSplit) -> Orientation {
        switch autoSplit {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        case .longerEdge:
            guard let f = frame else { return .horizontal }
            return f.width >= f.height ? .horizontal : .vertical
        }
    }

    // MARK: - Remove

    /// Remove `win`, collapsing its parent split and promoting the sibling.
    func remove(_ win: WinID) {
        guard let node = root?.findLeaf(win) else { return }
        guard let parent = node.parent else {
            // `node` is the root.
            root = nil
            focused = nil
            return
        }
        guard case .split(_, _, let a, let b) = parent.kind else { return }
        let sibling = (a === node) ? b : a
        replace(parent, with: sibling)

        // Refocus if the focused window is no longer present.
        if focused == nil || root?.findLeaf(focused!) == nil {
            focused = sibling.leftmostLeaf().windowID
        }
    }

    /// Swap `replace`d node into the slot held by `node` in its parent (or root).
    private func replace(_ node: BSPNode, with newNode: BSPNode) {
        guard let p = node.parent else {
            root = newNode
            newNode.parent = nil
            return
        }
        guard case .split(let o, let r, let a, let b) = p.kind else { return }
        if a === node {
            p.kind = .split(orientation: o, ratio: r, first: newNode, second: b)
        } else {
            p.kind = .split(orientation: o, ratio: r, first: a, second: newNode)
        }
        newNode.parent = p
    }

    // MARK: - Focus (geometry-based)

    /// Nearest leaf whose center lies in the half-plane toward `direction`.
    func adjacent(to win: WinID, direction: Direction, frames: [WinID: CGRect]) -> WinID? {
        guard let src = frames[win] else { return nil }
        let sc = CGPoint(x: src.midX, y: src.midY)
        var best: WinID?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (id, rect) in frames where id != win {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let inHalfPlane: Bool
            switch direction {
            case .left:  inHalfPlane = c.x < sc.x - 0.5
            case .right: inHalfPlane = c.x > sc.x + 0.5
            case .up:    inHalfPlane = c.y < sc.y - 0.5   // AX top-left: up = smaller y
            case .down:  inHalfPlane = c.y > sc.y + 0.5
            }
            guard inHalfPlane else { continue }
            let dx = abs(c.x - sc.x)
            let dy = abs(c.y - sc.y)
            let isHorizontal = (direction == .left || direction == .right)
            let travel = isHorizontal ? dx : dy        // distance in the direction of motion
            let misalignment = isHorizontal ? dy : dx  // off-axis offset
            // Weight misalignment heavily so we prefer the window directly in line,
            // not one that merely happens to be closer along the travel axis.
            let score = misalignment * 2.0 + travel
            if score < bestScore {
                bestScore = score
                best = id
            }
        }
        return best
    }

    // MARK: - Move / swap

    /// Swap the windows held by two leaves (preserves tree shape).
    func swap(_ a: WinID, _ b: WinID) {
        guard a != b, let na = root?.findLeaf(a), let nb = root?.findLeaf(b) else { return }
        na.kind = .leaf(b)
        nb.kind = .leaf(a)
    }

    // MARK: - Resize

    /// Resize the focused window relative to itself: `direction` slides the relevant
    /// divider toward that side, expanding the window that way (`right`/`down` move the
    /// divider toward +ratio, `left`/`up` toward −ratio). When the window is flush against
    /// the screen on that side there is nothing to expand into, so the opposite divider is
    /// pulled in instead and the window shrinks — it still responds. Either way the chosen
    /// divider moves in `direction`, so opposite directions reverse each other.
    func resize(_ win: WinID,
                direction: Direction,
                deltaPx: CGFloat,
                frames: [WinID: CGRect],
                minRatio: Double = 0.05) {
        guard let leaf = root?.findLeaf(win) else { return }
        let wantOrientation = direction.orientation
        let forward = (direction == .right || direction == .down)  // divider slides toward +ratio

        // Prefer the ancestor split whose divider — sliding toward `direction` — EXPANDS the
        // focused window (its subtree is on the side that grows). Fall back to the nearest
        // split where that same motion shrinks it: used when the window is flush to the screen
        // on `direction`'s side and so cannot expand that way.
        var expand: BSPNode?
        var shrink: BSPNode?
        var child: BSPNode = leaf
        var cursor = leaf.parent
        while let n = cursor {
            if case .split(let o, _, let a, _) = n.kind, o == wantOrientation {
                let isFirst = (a === child)
                // Sliding the divider toward `direction` grows the first child iff `forward`.
                if isFirst == forward { if expand == nil { expand = n } }
                else if shrink == nil { shrink = n }
            }
            child = n
            cursor = n.parent
        }

        guard let target = expand ?? shrink,
              case .split(let o, let r, let a, let b) = target.kind else {
            return  // No split on this axis: the window spans the full extent. No-op.
        }
        let rect = boundingRect(of: target, frames: frames)
        let extent = (o == .horizontal) ? rect.width : rect.height
        guard extent > 0 else { return }
        let dr = Double(deltaPx) / Double(extent)
        let clamped = Swift.max(minRatio, Swift.min(1 - minRatio, r + (forward ? dr : -dr)))
        target.kind = .split(orientation: o, ratio: clamped, first: a, second: b)
    }

    private func boundingRect(of node: BSPNode, frames: [WinID: CGRect]) -> CGRect {
        let rects = node.leafWindowIDs().compactMap { frames[$0] }
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - Balance / toggle

    /// Reset every split ratio to 0.5.
    func balance() {
        if let r = root { balanceNode(r) }
    }

    private func balanceNode(_ n: BSPNode) {
        if case .split(let o, _, let a, let b) = n.kind {
            n.kind = .split(orientation: o, ratio: 0.5, first: a, second: b)
            balanceNode(a)
            balanceNode(b)
        }
    }

    /// Flip the orientation of the focused window's parent split.
    func toggleSplitOrientation(of win: WinID) {
        guard let leaf = root?.findLeaf(win),
              let p = leaf.parent,
              case .split(let o, let r, let a, let b) = p.kind else { return }
        p.kind = .split(orientation: o.flipped, ratio: r, first: a, second: b)
    }

    // MARK: - Presets

    /// Rebuild the whole tree into `preset`, keeping the same window set and order.
    /// Manual ratios/split toggles are discarded by design (a preset is canonical).
    func applyPreset(_ preset: LayoutPreset, mainRatio: Double = 0.6) {
        let ids = root?.leafWindowIDs() ?? []
        guard !ids.isEmpty else { return }
        root = preset.build(ids, mainRatio: mainRatio)
        layoutPreset = preset
        // The window set is unchanged, so `focused` stays valid; re-point defensively.
        if let f = focused, root?.findLeaf(f) == nil {
            focused = root?.leftmostLeaf().windowID
        }
    }
}
