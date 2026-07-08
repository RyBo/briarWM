import ApplicationServices

/// Native-tab-aware window adoption. macOS tabs (e.g. Ghostty, Safari) surface as separate
/// AX windows stacked on the same frame, of which only the front one is the app's focused
/// window — so a tab group must occupy exactly one leaf, re-pointed at whichever tab is
/// visible. The tree never sees individual tabs.

/// What to do with an untracked window encountered during tab-aware adoption.
enum AdoptDecision: Equatable {
    case adopt            // a genuine standalone window → tile it
    case rebind(WinID)    // the front tab of an existing group → re-point that leaf in place
    case ignore           // a background tab on the visible desktop → never tile it
}

/// Pure tab-adoption decision. A window NOT stacked on an existing same-app tile
/// (`frameMatch == nil`) is a standalone/first window → adopt. A stacked window is a native
/// tab of that group unless `bothOnscreen`: the candidate and the matched leaf both on-screen
/// in the window server means two independent windows sharing a frame, since a settled tab
/// group shows one member at a time. (A tab create/switch can briefly show both, so a real tab
/// may be adopted for one pass; `dedupApp` collapses the stray leaf next pass once the old tab
/// is off-screen.) Otherwise take over the leaf if this window is the app's front (focused)
/// tab and the leaf isn't already claimed this pass; a background tab → ignore.
func tabDecision(frameMatch: WinID?, isFront: Bool, leafAlreadyUsed: Bool, bothOnscreen: Bool) -> AdoptDecision {
    guard let leaf = frameMatch else { return .adopt }
    if bothOnscreen { return .adopt }   // two independent windows stacked → tile the new one
    return (isFront && !leafAlreadyUsed) ? .rebind(leaf) : .ignore
}

/// Nearest leaf whose frame is within `tolerance` of `candidate` — i.e. the candidate is stacked
/// on it (a native tab joins its group at the group's current frame). Pure; a nil candidate or
/// no stacked leaf → nil.
func nearestStackedLeaf(_ candidate: CGRect?,
                        among leaves: [(id: WinID, frame: CGRect?)],
                        tolerance: CGFloat) -> WinID? {
    guard let c = candidate else { return nil }
    var best: WinID?
    var bestD = CGFloat.greatestFiniteMagnitude
    for l in leaves {
        guard let f = l.frame, rectsApproxEqual(f, c, tolerance) else { continue }
        let dx = f.midX - c.midX, dy = f.midY - c.midY
        let d = dx * dx + dy * dy        // squared distance — same ordering as distance
        if d < bestD { bestD = d; best = l.id }
    }
    return best
}

extension WindowManager {

    var manageTabs: Bool { config.layout.manageTabbedWindows }

    /// How close two windows' frames must be to count as "stacked" — i.e. native tabs of one
    /// group, which share the exact same frame (0px). Kept tight so it tolerates rounding. The
    /// cascade offset is NOT a reliable separator (some apps, e.g. Ghostty, open new windows at
    /// the previous window's exact frame); tabs vs. independent stacked windows are told apart
    /// by window-server on-screen state (`bothOnscreen`), not by this tolerance.
    private static let tabStackTolerance: CGFloat = 10

    /// Adopt / rebind / skip every untracked tileable window of one app.
    ///
    /// A new window stacked on an existing same-app tile is a tab: if it's the app's front tab
    /// it takes over that leaf in place (no reshuffle), otherwise it's a background tab and is
    /// skipped. A window not stacked on any tile is a genuine standalone window → adopt.
    /// Detection is pure AX (frame + focused window) — no private window-server calls — so
    /// it's robust to apps the CGS path can't id.
    func reconcileApp(pid: pid_t, dirty: inout Set<SpaceID>) {
        guard let app = apps[pid] else { return }
        // Self-populate the on-screen set when no batch pass holds one, so every caller —
        // present or future — gets tab disambiguation without its own capture.
        let ownsOnscreen = passOnscreen == nil
        if ownsOnscreen { passOnscreen = WindowServerSnapshot.onscreenIDs() }
        defer { if ownsOnscreen { passOnscreen = nil } }
        let focused = manageTabs ? app.focusedWindow() : nil
        var used: Set<WinID> = []
        for element in app.windows() where registry.id(for: element) == nil {
            let window = AXWindow(element: element, pid: pid)
            guard isTileable(window) else { continue }
            let decision = manageTabs ? classify(element, pid: pid, window: window, focused: focused, used: used) : .adopt
            switch decision {
            case .ignore:
                Log.logger.debug("tab ignore bg \(window.title ?? "?") @ \(frameStr(window.frame))")
                continue
            case .rebind(let leaf):
                registry.rebind(leaf, to: element, pid: pid)
                app.observe(window: element)
                used.insert(leaf)
                if let t = treeContaining(leaf) { dirty.insert(t.space) }
                Log.logger.debug("tab rebind \(leaf) → front \(window.title ?? "?") @ \(frameStr(window.frame))")
            case .adopt:
                considerWindow(element, pid: pid, retile: false)
                if let id = registry.id(for: element) {
                    app.observe(window: element)
                    if let t = treeContaining(id) { dirty.insert(t.space) }
                    Log.logger.debug("tab adopt \(id) \(window.title ?? "?") @ \(frameStr(window.frame))")
                }
            }
        }
        dedupApp(pid: pid, dirty: &dirty)   // collapse any leaves that ended up stacked (mistimed adoption)
    }

    /// Merge native-tab leaves that ended up stacked. Tabs of one group always share their actual
    /// on-screen frame (macOS keeps them stacked — `setFrame` moves the whole group), no matter
    /// what distinct tiles we assigned. So if two managed leaves of one app sit on the same actual
    /// frame, they're tabs of one group: keep the front tab's leaf and drop the rest. This is the
    /// backstop that recovers from any stray adoption of a background tab (e.g. an AX frame that
    /// wasn't stacked yet when the create notification fired). Runs without any retile in between,
    /// so removing the duplicate promotes the survivor back to the group's original tile.
    private func dedupApp(pid: pid_t, dirty: inout Set<SpaceID>) {
        guard manageTabs, let app = apps[pid] else { return }
        let focused = app.focusedWindow()
        func isFront(_ id: WinID) -> Bool {
            guard let f = focused, let el = registry.window(for: id)?.element else { return false }
            return CFEqual(f, el)
        }
        var entries: [(id: WinID, tree: BSPTree, frame: CGRect)] = []
        for (tree, id) in visibleTiledWindows() {
            guard let w = registry.window(for: id), w.pid == pid,
                  let f = currentFrame(id) else { continue }
            entries.append((id, tree, f))
        }
        var handled: Set<WinID> = []
        for i in entries.indices where !handled.contains(entries[i].id) {
            var cluster = [entries[i]]
            for j in entries.indices where j > i && !handled.contains(entries[j].id)
                && rectsApproxEqual(entries[i].frame, entries[j].frame, Self.tabStackTolerance) {
                cluster.append(entries[j])
            }
            cluster.forEach { handled.insert($0.id) }
            guard cluster.count > 1 else { continue }
            let keep = cluster.first(where: { isFront($0.id) }) ?? cluster[0]
            if let f = focused, registry.id(for: f) == nil {        // ensure the survivor shows the front tab
                registry.rebind(keep.id, to: f, pid: pid)
                app.observe(window: f)
            }
            let keepOnscreen = onscreen(keep.id)
            for c in cluster where c.id != keep.id {
                if keepOnscreen && onscreen(c.id) { continue }   // both on-screen → independent, don't collapse
                Log.logger.info("tab dedup: drop stacked leaf \(c.id) (kept \(keep.id)) @ \(frameStr(c.frame))")
                forget(c.id, tree: c.tree, newFocus: keep.id)
                dirty.insert(c.tree.space)
            }
            dirty.insert(keep.tree.space)
        }
    }

    /// Decide what to do with one untracked window: is it stacked on an existing same-app tile
    /// (→ a native tab), and if so is it the app's front (focused) window?
    private func classify(_ element: AXUIElement, pid: pid_t, window: AXWindow,
                          focused: AXUIElement?, used: Set<WinID>) -> AdoptDecision {
        let leaf = frameMatchLeaf(pid: pid, frame: window.frame)
        let isFront = focused.map { CFEqual($0, element) } ?? false
        let claimed = leaf.map { used.contains($0) } ?? false
        let independent = leaf.map { onscreen(element) && onscreen($0) } ?? false
        return tabDecision(frameMatch: leaf, isFront: isFront, leafAlreadyUsed: claimed,
                           bothOnscreen: independent)
    }

    /// Whether a window is confirmed on-screen this pass. Fails closed: no pass snapshot / no
    /// window-server id → false, i.e. fall back to the frame-only tab heuristic.
    private func onscreen(_ element: AXUIElement) -> Bool {
        guard let onscreen = passOnscreen, let wid = spaces.cgWindowID(for: element) else { return false }
        return onscreen.contains(wid)
    }

    private func onscreen(_ id: WinID) -> Bool {
        guard let el = registry.window(for: id)?.element else { return false }
        return onscreen(el)
    }

    /// The managed same-app leaf the given window is stacked on (a native tab joins its group at
    /// the group's frame), or nil if it sits on no existing tile — i.e. it's a standalone window.
    private func frameMatchLeaf(pid: pid_t, frame: CGRect?) -> WinID? {
        var leaves: [(id: WinID, frame: CGRect?)] = []
        for (_, id) in visibleTiledWindows() {
            guard let w = registry.window(for: id), w.pid == pid, !w.isMinimized else { continue }
            leaves.append((id, currentFrame(id) ?? desiredFrames[id]))
        }
        return nearestStackedLeaf(frame, among: leaves, tolerance: Self.tabStackTolerance)
    }

    /// On a front-tab close, macOS promotes the next tab to the app's focused window. If that
    /// promoted window is untracked and stacked on the vacated tile, return it so the leaf can
    /// rebind to it instead of collapsing. A normal single-window close has no such sibling → nil.
    func promotedTabSibling(forClosing id: WinID, pid: pid_t) -> AXUIElement? {
        // No on-screen gate here: at front-tab-close the promoted tab is already on-screen, so the
        // signal can't distinguish. When the signal was available, `classify` adopted independent
        // windows into distinct leaves so they no longer share the vacated frame; in degraded mode
        // this behaves exactly as before the gate existed.
        guard manageTabs, let app = apps[pid], let vacated = desiredFrames[id],
              let focused = app.focusedWindow(), registry.id(for: focused) == nil else { return nil }
        let w = AXWindow(element: focused, pid: pid)
        guard w.subrole == (kAXStandardWindowSubrole as String), !w.isMinimized,
              let f = w.frame, rectsApproxEqual(f, vacated, Self.tabStackTolerance) else { return nil }
        return focused
    }

    private func frameStr(_ r: CGRect?) -> String {
        guard let r = r else { return "nil" }
        return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }
}
