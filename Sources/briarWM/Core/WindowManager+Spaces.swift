import ApplicationServices

/// Desktop (macOS Space) reconciliation and display reconfiguration: keeping each tree on
/// the display that owns its Space, re-homing windows that drifted, reaping dead windows,
/// and parking/restoring trees across monitor sleep/unplug.
extension WindowManager {

    /// The timer-driven backstop reconcile. When the window server's structural state is
    /// unchanged since the last tick — nothing appeared, closed, minimized, moved, or
    /// switched desktops — skip the whole sweep, so an idle system costs one CG call per
    /// tick instead of a per-app AX sweep. Notification-driven reconciles (Space switch,
    /// app activation, display reconfig, wake) call `reconcileSpaces` directly and never
    /// skip.
    func pollReconcile() {
        // Self-heal path for the sleep suspension: if every wake notification was missed,
        // the first tick with a lit display resumes reconciliation.
        if reconcileSuspended {
            guard screens.anyDisplayAwake else { return }
            reconcileSuspended = false
            Log.logger.info("displays awake — reconcile resumed (poll)")
        }
        let snapshot = WindowServerSnapshot.capture()
        if let snapshot, snapshot == lastPollSnapshot {
            Log.logger.trace("poll: window server unchanged — skip reconcile")
            return
        }
        lastPollSnapshot = snapshot
        // The snapshot's keys ARE the on-screen set — seed the pass with them so
        // `reconcileSpaces` doesn't repeat the CG call. nil snapshot → let it capture.
        let ownsOnscreen = passOnscreen == nil
        if ownsOnscreen { passOnscreen = snapshot.map { Set($0.windows.keys) } }
        defer { if ownsOnscreen { passOnscreen = nil } }
        reconcileSpaces()
    }

    /// Re-home every managed window whose real Space no longer matches the tree it's in,
    /// then re-tile the visible desktops. Active trees apply frames — closing the gap on
    /// the source desktop and sizing windows on the destination; hidden trees only
    /// recompute. No-op without Space support. Cheap enough for the backstop timer.
    ///
    /// `moveFocus` is true only for a genuine user-facing Space switch (the
    /// `activeSpaceDidChange` notification) — then focus is asserted onto the now-visible
    /// desktop. Every other caller (the backstop poll, app activation, display reconfig,
    /// resync) leaves it false so reconciliation only *repairs the focus cache* and never
    /// steals OS keyboard focus out from under the user.
    func reconcileSpaces(moveFocus: Bool = false) {
        guard !reconcileSuspended else { return }      // displays asleep: every signal is garbage
        refreshActiveSpaces()                          // (1) keep activeSpace fresh
        passFrames = snapshotVisibleFrames()           // one AX read per window for the whole pass
        defer { passFrames = nil }
        // One on-screen capture for the whole per-app loop + dedup — unless a caller
        // (the poll's snapshot seed) already holds one.
        let ownsOnscreen = passOnscreen == nil
        if ownsOnscreen { passOnscreen = WindowServerSnapshot.onscreenIDs() }
        defer { if ownsOnscreen { passOnscreen = nil } }
        var dirty: Set<SpaceID> = []

        // (2) Tab-aware discover/adopt/rebind/skip for every app: picks up windows whose
        // Space was hidden at startup, and keeps native tab groups to a single tile that
        // follows the front tab.
        for pid in Array(apps.keys) { reconcileApp(pid: pid, dirty: &dirty) }

        // (3) Reap windows whose AX element is gone — the backstop for a missed/misdirected
        // destroy notification (Firefox). After the rebind pass above so a promoted sibling
        // rescues a dead front tab instead of being reaped + re-adopted. Needs only AX (not
        // Spaces), so it runs in pseudo-Space mode too.
        dirty.formUnion(reapDeadWindows())

        guard spaces.isAvailable else {                // pseudo-Space mode: just apply adoptions
            retileDirtyAndVisible(dirty)
            notifyFocusOverlay(pulse: false)
            return
        }

        let spaceDisplay = spaceDisplayMap()           // space → owning display, current layout

        // Keep each tree on the display that currently owns its Space. Display ids and
        // space→display assignments both drift across a monitor reconnect, and a stale
        // `tree.display` silently breaks everything keyed off it: `isActive` (activeSpace is
        // keyed by display), `retile` (the screen is keyed by display), and new-window
        // placement. Re-pointing here makes the backstop poll self-heal what used to require
        // a briarWM restart.
        repointTreesToOwningDisplay(spaceDisplay, dirty: &dirty)
        rehomeDriftedWindows(spaceDisplay, dirty: &dirty)

        retileDirtyAndVisible(dirty)
        repairFocusCache(moveFocus: moveFocus)
        notifyFocusOverlay(pulse: false)               // reposition/hide after a Space shuffle
    }

    /// Re-point each tree at the display that currently owns its Space, marking any that moved dirty.
    private func repointTreesToOwningDisplay(_ spaceDisplay: [SpaceID: DisplayID], dirty: inout Set<SpaceID>) {
        for tree in trees.values {
            guard let d = spaceDisplay[tree.space], d != tree.display else { continue }
            Log.logger.info("re-point tree space \(tree.space): display \(tree.display) → \(d)")
            tree.display = d
            dirty.insert(tree.space)
        }
    }

    /// Re-home each tiled window whose real Space drifted from its tree (float one seen spanning
    /// every desktop twice running), marking both source and destination Spaces dirty.
    private func rehomeDriftedWindows(_ spaceDisplay: [SpaceID: DisplayID], dirty: inout Set<SpaceID>) {
        // Phase 1: scan without re-homing. Float sticky windows inline (a single-window op),
        // but only *record* genuine drifts, grouped by (source tree, destination Space). The
        // grouping is computed against this stable snapshot of `trees` because phase 2's
        // `ensureTree` can add entries — a group must reflect the pre-move layout.
        var pending: [ObjectIdentifier: (src: BSPTree, dests: [SpaceID: Set<WinID>])] = [:]
        for tree in Array(trees.values) {                 // snapshot: phase 2 mutates `trees`
            for id in tree.windowIDs where !registry.isFloating(id) {
                guard let element = registry.window(for: id)?.element,
                      let wid = spaces.cgWindowID(for: element) else { continue }
                let ids = spaces.spaceIDs(for: wid)
                if ids.count > 1 {                        // sticky twice in a row → float it
                    guard stickyOnce.contains(id) else { stickyOnce.insert(id); continue }
                    Log.logger.info("float sticky window \(id) (spans \(ids.count) spaces twice running)")
                    detach(id, from: tree)
                    registry.setFloating(id, true)
                    dirty.insert(tree.space)
                    continue
                }
                stickyOnce.remove(id)
                guard let real = ids.first, real != tree.space else { continue }
                // If this fires every tick for windows you never moved, the window-server's
                // window→Space numbering disagrees with the managed-space dict key — see
                // SpacesManager.spaceID(from:) and switch the preferred key.
                pending[ObjectIdentifier(tree), default: (tree, [:])].dests[real, default: []].insert(id)
            }
        }

        // Phase 2: move each group as one intact subtree, so a whole desktop migrated at once
        // (lid close/open) keeps its arrangement instead of being re-inserted window-by-window.
        // A one-leaf group behaves exactly like the old single-window insert (via insertSubtree).
        for (src, dests) in pending.values {
            for (dstSpace, moved) in dests {
                guard let subtree = src.root?.pruned(keeping: { moved.contains($0) }) else { continue }
                src.removeAll(moved)
                for id in moved { clearSlotBookkeeping(id, from: src) }
                let dst = ensureTree(space: dstSpace, display: spaceDisplay[dstSpace] ?? src.display)
                dst.insertSubtree(subtree, focusedFrame: insertionHint(for: dst),
                                  autoSplit: autoSplit, ratio: config.layout.defaultRatio)
                dirty.insert(src.space)
                dirty.insert(dstSpace)
                Log.logger.info("reconcile: moved \(moved.count) window(s) space \(src.space) → \(dstSpace) as intact subtree")
            }
        }
    }

    /// Refresh the visible Space per display from the window server (or pseudo-Spaces).
    /// Skip displays whose current Space isn't a user desktop: while the screen is locked
    /// the loginwindow Space is reported as current, and recording it would make `isActive`
    /// false for every real tree (tiling silently stops). Keeping the last-known-good user
    /// Space through the locked interval lets `resync()` restore tiling cleanly on unlock.
    func refreshActiveSpaces() {
        if spaces.isAvailable {
            for ds in spaces.displayLayout() where ds.currentIsUserSpace {
                guard let d = ds.displayID else { continue }
                if let old = activeSpace[d], old != ds.currentSpace { lastSpace[d] = old }
                activeSpace[d] = ds.currentSpace
            }
        }
        for d in screens.displayIDs where activeSpace[d] == nil { activeSpace[d] = pseudoSpace(d) }
    }

    /// Resolve the desktop a window currently lives on. `sticky` ⇒ it spans multiple
    /// Spaces (treat as floating). Falls back to the display's pseudo-Space.
    func resolveSpace(_ window: AXWindow, display: DisplayID) -> (space: SpaceID, sticky: Bool) {
        guard spaces.isAvailable, let wid = spaces.cgWindowID(for: window.element) else {
            return (pseudoSpace(display), false)
        }
        let ids = spaces.spaceIDs(for: wid)
        if ids.count > 1 { return (pseudoSpace(display), true) }
        return (ids.first ?? pseudoSpace(display), false)
    }

    /// One live AX frame read per visible tiled window — the pass snapshot backing
    /// `currentFrame(_:)` for the duration of a reconcile pass.
    private func snapshotVisibleFrames() -> [WinID: CGRect] {
        var out: [WinID: CGRect] = [:]
        for (_, id) in visibleTiledWindows() {
            if let f = registry.window(for: id)?.frame { out[id] = f }
        }
        return out
    }

    /// The current window-server layout entry for `display`, or nil when Space queries are
    /// unavailable or the display isn't in the layout.
    func displayLayoutEntry(for display: DisplayID) -> DisplaySpaces? {
        spaces.displayLayout().first { $0.displayID == display }
    }

    /// space → owning display, from the current window-server layout. Empty when Space queries
    /// are unavailable. Drives both `reconcileSpaces` re-homing and parked-tree restoration.
    private func spaceDisplayMap() -> [SpaceID: DisplayID] {
        var map: [SpaceID: DisplayID] = [:]
        for ds in spaces.displayLayout() {
            guard let d = ds.displayID else { continue }
            for s in ds.spaces { map[s.id] = d }
        }
        return map
    }

    // MARK: - Dead-window reaping

    /// Remove managed windows whose AX element is gone — the backstop for a missed/misdirected
    /// `kAXUIElementDestroyed` (notably Firefox). Returns the Spaces that need a retile. Never
    /// reaps a merely hidden / off-Space / occluded window (their elements still answer AX).
    private func reapDeadWindows() -> Set<SpaceID> {
        var scanned = 0
        var dead: [(tree: BSPTree, id: WinID)] = []
        for tree in Array(trees.values) + parkedTrees {   // parked trees leak too if dead-but-registered
            for id in tree.windowIDs where !registry.isFloating(id) {
                scanned += 1
                guard let w = registry.window(for: id), isDead(w) else { continue }
                dead.append((tree, id))
            }
        }

        // Circuit breaker: most-of-everything reading dead at once is a display-sleep /
        // window-server transition, not real (Cmd-Q cleanup arrives via removeApp, never
        // here). Believe it only when the exact same set reads dead on the next pass too —
        // a real mass close survives the retry, a transition clears within one tick.
        let deadIDs = Set(dead.map(\.id))
        if dead.count >= 2, dead.count * 2 > scanned, deadIDs != pendingMassReap {
            pendingMassReap = deadIDs
            Log.logger.info("reap deferred: \(dead.count)/\(scanned) windows read dead at once")
            return []
        }
        pendingMassReap = []

        var dirty: Set<SpaceID> = []
        for (tree, id) in dead {
            Log.logger.info("reap dead window \(id)")
            forget(id, tree: tree)
            if trees[tree.space] === tree { dirty.insert(tree.space) }   // parked: recompute only
        }
        return dirty
    }

    /// True once a window is gone. Corroborate `!exists` with a missing window-server id when
    /// Spaces are available, so a momentarily-unresponsive (but alive) app isn't reaped.
    private func isDead(_ w: AXWindow) -> Bool {
        if w.exists { return false }
        if spaces.isAvailable { return spaces.cgWindowID(for: w.element) == nil }
        return true
    }

    // MARK: - Display reconfiguration

    func screensChanged() {
        screens.refresh()
        refreshActiveSpaces()
        let valid = Set(screens.displayIDs)
        guard !valid.isEmpty else { return }   // every display gone (system sleeping): keep trees intact

        // Park trees whose display vanished instead of destroying their layout. They leave
        // `trees` (so they never retile) and wait in `parkedTrees` for the monitor to return.
        // (Snapshot first — we mutate `trees` in the loop.)
        let orphaned = trees.filter { !valid.contains($0.value.display) }
        for (space, tree) in orphaned {
            trees.removeValue(forKey: space)
            parkedTrees.append(tree)
            Log.logger.info("park tree space \(space) (display \(tree.display) gone)")
        }

        // Restore parked trees whose display is back (keyed by Space, stable across reconnect).
        let spaceOwner = spaceDisplayMap()
        var stillParked: [BSPTree] = []
        for tree in parkedTrees {
            guard let display = DisplayReconfig.restoreDisplay(
                    space: tree.space, originalDisplay: tree.display,
                    valid: valid, spaceOwner: spaceOwner) else {
                stillParked.append(tree); continue
            }
            restorePark(tree, onto: display)
        }
        parkedTrees = stillParked

        reconcileSpaces()
        retileAll()
        notifyFocusOverlay(pulse: false)               // land the overlay on the right screen
    }

    /// Reinstate a parked tree on a (re)connected display. Prunes windows that closed while the
    /// monitor was gone, re-points the tree at `display` (its id may have changed), and folds
    /// into an existing tree if one already holds the Space. A tree emptied while parked is
    /// dropped (the caller leaves it out of `parkedTrees`).
    private func restorePark(_ tree: BSPTree, onto display: DisplayID) {
        for id in tree.windowIDs where registry.window(for: id) == nil { tree.remove(id) }
        guard !tree.isEmpty else { return }
        tree.display = display
        if let existing = trees[tree.space], existing !== tree {
            existing.insertSubtree(tree.root!, focusedFrame: nil, autoSplit: autoSplit,
                                   ratio: config.layout.defaultRatio)
        } else {
            trees[tree.space] = tree
        }
        Log.logger.info("restore tree space \(tree.space) onto display \(display)")
    }
}
