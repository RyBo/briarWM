import CoreGraphics

enum InsertAt: String {
    case after, before
}

/// One BSP tree per display. Pure data structure + algorithms; knows nothing
/// about the Accessibility API. Geometry-dependent operations (focus/resize)
/// take a precomputed `frames` map so they stay testable.
final class BSPTree {
    let display: DisplayID
    var root: BSPNode?
    var focused: WinID?
    /// bspwm-style preselection: orientation to use for the *next* insert.
    var preselect: Orientation?

    init(display: DisplayID) { self.display = display }

    var isEmpty: Bool { root == nil }
    var windowIDs: [WinID] { root?.leafWindowIDs() ?? [] }
    func contains(_ id: WinID) -> Bool { root?.findLeaf(id) != nil }

    // MARK: - Insert

    /// Insert `win` by splitting the focused leaf (bspwm "automatic" mode).
    /// `focusedFrame` is the current rect of the focused window, used to pick the
    /// split orientation along its longer edge when no preselection is set.
    @discardableResult
    func insert(_ win: WinID,
                focusedFrame: CGRect? = nil,
                insertAt: InsertAt = .after,
                autoSplit: String = "longer_edge") -> Bool {
        guard root != nil else {
            root = BSPNode(leaf: win)
            focused = win
            return true
        }

        let target: BSPNode
        if let f = focused, let node = root?.findLeaf(f) {
            target = node
        } else {
            target = root!.rightmostLeaf()
        }
        guard let oldWin = target.windowID else { return false }

        let orientation = preselect ?? autoOrientation(focusedFrame, autoSplit: autoSplit)
        preselect = nil

        let oldLeaf = BSPNode(leaf: oldWin)
        let newLeaf = BSPNode(leaf: win)
        let (first, second) = (insertAt == .after) ? (oldLeaf, newLeaf) : (newLeaf, oldLeaf)
        let split = BSPNode(split: orientation, ratio: 0.5, first: first, second: second)
        replace(target, with: split)
        focused = win
        return true
    }

    private func autoOrientation(_ frame: CGRect?, autoSplit: String) -> Orientation {
        switch autoSplit {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        default:
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
        if let f = focused, root?.findLeaf(f) != nil {
            // still valid
        } else {
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

    /// Move the focused window's `direction` edge outward by `deltaPx` by adjusting
    /// the nearest ancestor split on the matching axis with a sibling on that side.
    func resize(_ win: WinID,
                edge direction: Direction,
                deltaPx: CGFloat,
                frames: [WinID: CGRect],
                minRatio: Double = 0.05) {
        guard let leaf = root?.findLeaf(win) else { return }
        let wantOrientation = direction.orientation
        // Forward edges (right/down): our subtree must be the FIRST child  -> grow ratio.
        // Backward edges (left/up):   our subtree must be the SECOND child -> shrink ratio.
        let wantFirst = (direction == .right || direction == .down)

        var child: BSPNode = leaf
        var cursor = leaf.parent
        while let n = cursor {
            if case .split(let o, let r, let a, let b) = n.kind, o == wantOrientation {
                let isFirst = (a === child)
                if isFirst == wantFirst {
                    let rect = boundingRect(of: n, frames: frames)
                    let extent = (o == .horizontal) ? rect.width : rect.height
                    if extent > 0 {
                        let dr = Double(deltaPx) / Double(extent)
                        let newRatio = wantFirst ? r + dr : r - dr
                        let clamped = Swift.max(minRatio, Swift.min(1 - minRatio, newRatio))
                        n.kind = .split(orientation: o, ratio: clamped, first: a, second: b)
                    }
                    return
                }
            }
            child = n
            cursor = n.parent
        }
        // No suitable split: window is flush against that edge of the screen. No-op.
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
}
