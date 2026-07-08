import Foundation

/// Layout persistence: save every tree's shape to disk (debounced) and restore it on the next
/// startup by exact window-server-id matching, so a briarWM restart *within the same login
/// session* brings back the identical arrangement. Always on, no config knob.
///
/// The whole thing gates on `spaces.canIdentifyWindows` (weaker than `isAvailable`): all it
/// needs is the AX-element → window-server-id map, so it works in pseudo-Space mode too. A
/// snapshot from a previous boot is detected stale (its window-server ids are recycled) via
/// `kern.boottime` and discarded — plain adoption then applies.
extension WindowManager {

    // MARK: - Save

    /// Trailing ~1s debounce. Every retile reschedules this, so the retile storm during a
    /// reflow collapses into a single disk write once things settle.
    func scheduleLayoutSave() {
        guard spaces.canIdentifyWindows else { return }
        layoutSaveTimer?.invalidate()
        layoutSaveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.saveLayoutNow()
        }
    }

    /// Write the current layout now (also flushed on shutdown). No-op when window identity is
    /// unavailable or `kern.boottime` can't be read (without it a restored snapshot couldn't be
    /// validated). Cancels any pending debounce so a flush doesn't double-fire.
    func saveLayoutNow() {
        layoutSaveTimer?.invalidate()
        layoutSaveTimer = nil
        guard spaces.canIdentifyWindows else { return }
        guard let bootTime = LayoutStore.currentBootTime() else {
            Log.logger.debug("layout save skipped: kern.boottime unavailable")
            return
        }
        let winToCG: (WinID) -> WindowServerID? = { id in
            guard let element = self.registry.window(for: id)?.element else { return nil }
            return self.spaces.cgWindowID(for: element)
        }
        var snapshots: [TreeSnapshot] = []
        for tree in Array(trees.values) + parkedTrees {
            // A desktop still awaiting its pending restore is saved as the queued shape, not
            // the live tree — a restart before the user ever visits it must not flatten it.
            guard pendingRestore[tree.space] == nil else { continue }
            guard let root = tree.root, let encoded = TreeSnapshotCodec.encode(root, id: winToCG) else { continue }
            snapshots.append(TreeSnapshot(space: tree.space, display: tree.display,
                                          focused: tree.focused.flatMap(winToCG),
                                          layoutPreset: tree.layoutPreset?.rawValue,
                                          root: encoded))
        }
        snapshots.append(contentsOf: pendingRestore.values)
        guard !snapshots.isEmpty else { return }
        LayoutStore.save(LayoutSnapshot(savedAt: Date(), bootTime: bootTime, trees: snapshots))
    }

    // MARK: - Restore

    /// Load the on-disk layout and queue every desktop's shape as a pending restore. Called
    /// once from `start()` between `adoptExistingWindows()` and `retileAll()`. The visible
    /// desktops apply immediately; hidden ones can't (CGS reports nothing for off-screen
    /// windows, so their windows sit in a pseudo-Space tree until first discovered) — their
    /// shapes stay queued and `applyPendingRestores` re-applies them from the reconcile pass
    /// as windows surface, finalizing when the desktop is first seen.
    func restoreLayout() {
        guard spaces.canIdentifyWindows else { return }
        guard let snap = LayoutStore.load() else { return }
        LayoutStore.delete()   // invalidate-after-use: never restore the same file twice

        // A snapshot from before the last reboot can't be matched — window-server ids are
        // recycled per boot. `kern.boottime` shifts a little on NTP slews, so allow 5 minutes.
        guard let boot = LayoutStore.currentBootTime(),
              abs(snap.bootTime.timeIntervalSince(boot)) <= 300 else {
            Log.logger.debug("layout snapshot from a different boot — ignoring")
            return
        }

        for ts in snap.trees where ts.root != nil { pendingRestore[ts.space] = ts }
        pendingRestoreExpiry = Date().addingTimeInterval(600)
        var dirty: Set<SpaceID> = []
        applyPendingRestores(dirty: &dirty)   // start() retiles everything right after
        if !pendingRestore.isEmpty {
            Log.logger.info("layout restore: \(pendingRestore.count) desktop(s) deferred until their windows surface")
        }
    }

    /// Apply queued desktop shapes to their live trees. Rearranges only windows already tiled
    /// in that Space's tree — it never resurrects closed windows or parked trees, so a
    /// window's live Space always wins over the snapshot's. A desktop keeps re-applying as
    /// more of its windows are discovered (invisible while hidden), and its entry is dropped
    /// on the first pass where the desktop is user-visible — after that the user's own
    /// rearrangements are never overwritten. Entries expire ten minutes after startup.
    func applyPendingRestores(dirty: inout Set<SpaceID>) {
        guard !pendingRestore.isEmpty else { return }
        if let expiry = pendingRestoreExpiry, Date() > expiry {
            Log.logger.info("layout restore: dropping \(pendingRestore.count) never-seen desktop(s) (expired)")
            pendingRestore.removeAll()
            return
        }
        let visible = Set(activeSpace.values)
        for (space, ts) in Array(pendingRestore) {
            guard let t = trees[space], !t.isEmpty, let snapRoot = ts.root else { continue }

            // window-server id → live WinID, over this tree's members only: the snapshot
            // merely rearranges within the desktop.
            var cgToWin: [WindowServerID: WinID] = [:]
            for id in t.windowIDs {
                guard let element = registry.window(for: id)?.element,
                      let cg = spaces.cgWindowID(for: element) else { continue }
                cgToWin[cg] = id
            }
            let resolve: (WindowServerID) -> WinID? = { cgToWin[$0] }
            guard let newRoot = TreeSnapshotCodec.rebuild(snapRoot, resolve: resolve) else { continue }

            // Windows in the tree today that the snapshot didn't place (opened before restore,
            // or dropped from the snapshot). Capture BEFORE swapping the root; re-inserted after
            // in their existing in-order sequence.
            let placed = Set(newRoot.leafWindowIDs())
            let leftovers = t.windowIDs.filter { !placed.contains($0) }

            t.root = newRoot
            t.layoutPreset = ts.layoutPreset.flatMap(LayoutPreset.init(rawValue:))
            for id in leftovers {
                t.insert(id, focusedFrame: insertionHint(for: t),
                         insertAt: InsertAt(rawValue: config.layout.insertAt) ?? .after,
                         autoSplit: autoSplit, ratio: config.layout.defaultRatio)
            }
            // Restore focus last — `insert` above moves `focused` onto each leftover.
            t.focused = ts.focused.flatMap(resolve) ?? t.root?.leftmostLeaf().windowID
            dirty.insert(space)

            if visible.contains(space) {
                pendingRestore.removeValue(forKey: space)
                Log.logger.info("layout restore: placed \(placed.count) window(s) on desktop \(space)")
            }
        }
    }
}
