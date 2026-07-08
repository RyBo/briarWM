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
            guard let root = tree.root, let encoded = TreeSnapshotCodec.encode(root, id: winToCG) else { continue }
            snapshots.append(TreeSnapshot(space: tree.space, display: tree.display,
                                          focused: tree.focused.flatMap(winToCG),
                                          layoutPreset: tree.layoutPreset?.rawValue,
                                          root: encoded))
        }
        guard !snapshots.isEmpty else { return }
        LayoutStore.save(LayoutSnapshot(savedAt: Date(), bootTime: bootTime, trees: snapshots))
    }

    // MARK: - Restore

    /// Restore the on-disk layout onto the freshly-adopted trees. Called once from `start()`
    /// between `adoptExistingWindows()` and `retileAll()`. Rearranges only windows that are
    /// *already* tiled — it never resurrects closed windows or parked trees — so a window's
    /// live Space always wins over the snapshot's.
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

        // window-server id → live WinID, over every window currently tiled.
        var cgToWin: [WindowServerID: WinID] = [:]
        for tree in trees.values {
            for id in tree.windowIDs {
                guard let element = registry.window(for: id)?.element,
                      let cg = spaces.cgWindowID(for: element) else { continue }
                cgToWin[cg] = id
            }
        }

        var restoredWindows = 0
        var restoredTrees = 0
        for ts in snap.trees {
            guard let t = trees[ts.space], let snapRoot = ts.root else { continue }
            // Only place a window that lives in *this* tree right now: its live Space wins,
            // the snapshot merely rearranges within it.
            let resolve: (WindowServerID) -> WinID? = { cg in
                cgToWin[cg].flatMap { t.contains($0) ? $0 : nil }
            }
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

            restoredWindows += placed.count
            restoredTrees += 1
        }
        Log.logger.info("layout restore: placed \(restoredWindows) window(s) across \(restoredTrees) desktop(s)")
    }
}
