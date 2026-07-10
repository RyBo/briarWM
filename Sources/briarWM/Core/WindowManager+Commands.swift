import AppKit

/// Everything the `CommandRouter` dispatches — the hotkey-driven command vocabulary —
/// plus the hotkey → action plumbing itself.
extension WindowManager {

    // MARK: - Hotkeys

    func handleHotkey(_ combo: KeyCombo) {
        guard let action = keymap.action(for: combo, mode: currentMode) else { return }
        Log.logger.debug("action \(String(describing: action)) [mode=\(currentMode)]")
        router.perform(action)
    }

    func applyKeymap() {
        hotkeys.setHotkeys(keymap.combos(for: currentMode))
    }

    // MARK: - Focus / move / resize

    func focusDirection(_ dir: Direction) {
        guard let (fid, tree) = activeTarget() else { return }
        var frames: [WinID: CGRect] = [:]
        for (t, id) in visibleTiledWindows()
        where config.layout.focusWrapsMonitors || t.display == tree.display {
            if let f = desiredFrames[id] { frames[id] = f }
        }
        if let target = tree.adjacent(to: fid, direction: dir, frames: frames) {
            focus(windowID: target)
        }
    }

    func moveDirection(_ dir: Direction) {
        guard let (fid, tree) = activeTarget(),
              let target = tree.adjacent(to: fid, direction: dir, frames: visibleFrames()),
              let targetTree = treeContaining(target) else { return }
        if targetTree === tree {
            tree.swap(fid, target)
            retile(tree)
        } else {
            // detach (not raw remove) so a fullscreen window doesn't stay zoomed on the
            // destination monitor; honor the configured auto_split on the cross-tree insert.
            detach(fid, from: tree)
            targetTree.insert(fid, focusedFrame: desiredFrames[target],
                              autoSplit: autoSplit, ratio: config.layout.defaultRatio)
            targetTree.focused = fid
            focusedID = fid
            retile(tree)
            retile(targetTree)
        }
    }

    func resizeFocused(_ dir: Direction, _ px: CGFloat) {
        guard let (fid, tree) = activeTarget() else { return }
        tree.resize(fid, direction: dir, deltaPx: px, frames: desiredFrames)
        retile(tree)
    }

    // MARK: - Layout

    func preselect(_ orientation: Orientation) {
        guard let (_, tree) = activeTarget() else { return }
        tree.preselect = orientation
    }

    func toggleSplit() {
        guard let (fid, tree) = activeTarget() else { return }
        tree.toggleSplitOrientation(of: fid)
        retile(tree)
    }

    func balanceFocusedDisplay() {
        guard let (_, tree) = activeTarget() else { return }
        tree.balance()
        retile(tree)
    }

    /// Snap the active desktop to the next preset in the configured cycle (tmux-style).
    func cycleLayout() {
        guard let (_, tree) = activeTarget() else { return }
        guard let next = LayoutPreset.next(after: tree.layoutPreset, in: resolvedPresetCycle()) else { return }
        tree.applyPreset(next, mainRatio: config.layout.mainRatio)
        retile(tree)
    }

    /// Snap the active desktop to a specific preset (e.g. bound to `layout tiled`).
    func setLayout(_ preset: LayoutPreset) {
        guard let (_, tree) = activeTarget() else { return }
        tree.applyPreset(preset, mainRatio: config.layout.mainRatio)
        retile(tree)
    }

    /// The configured preset cycle, parsed to enum cases. Unknown tokens are dropped;
    /// an empty/all-invalid list falls back to every preset so the hotkey always works.
    private func resolvedPresetCycle() -> [LayoutPreset] {
        let parsed = config.layout.presetCycle.compactMap(LayoutPreset.init(token:))
        return parsed.isEmpty ? LayoutPreset.allCases : parsed
    }

    // MARK: - Window state

    func toggleFullscreen() {
        guard let (fid, tree) = activeTarget() else { return }
        zoomedID = (zoomedID == fid) ? nil : fid
        retile(tree)
    }

    func toggleFloatFocused() {
        guard let fid = focusedID else { return }
        if registry.isFloating(fid) {
            registry.setFloating(fid, false)
            let display = displayForID(fid) ?? screens.displayIDs.first ?? 0
            let space = registry.window(for: fid).map { resolveSpace($0, display: display).space }
                ?? activeSpace[display] ?? pseudoSpace(display)
            let tree = ensureTree(space: space, display: display)
            // In workspace-float mode this window becomes the lone tiled one; toggle-off
            // re-inserts it via the pre-existing-tiled path, so drop it from the float set.
            tree.workspaceFloat?.floated.remove(fid)
            tree.insert(fid, focusedFrame: insertionHint(for: tree),
                        autoSplit: autoSplit, ratio: config.layout.defaultRatio)
            retile(tree)
        } else if let tree = treeContaining(fid) {
            // Route through detach (not raw tree.remove) so a zoomed window doesn't keep
            // zoomedID set — otherwise unfloating it later re-applies the fullscreen
            // override. newFocus: fid keeps focus on the window we just floated.
            detach(fid, from: tree, newFocus: fid)
            registry.setFloating(fid, true)
            // Re-floating a window that was manually tiled during workspace-float mode: put
            // it back in the set so toggle-off doesn't leave it stranded as a float.
            tree.workspaceFloat?.floated.insert(fid)
            retile(tree)
        }
        // The focused window is now a float (or newly tiled) — retile's internal notify only
        // fires for windows in the retiled tree, so push the overlay update explicitly here.
        notifyFocusOverlay(pulse: false)
    }

    /// Float the whole current desktop so windows drag freely; press again to snap every
    /// survivor back to the exact prior tiled layout. The tree empties while the mode is on,
    /// which makes it inert to retile/rehome/reap — new windows adopted meanwhile float too
    /// and tile in on toggle-off.
    func toggleWorkspaceFloat() {
        // `activeTarget()` can't resolve the target here — the tree is empty during the mode,
        // so derive the active desktop from the focused window's display directly.
        let display = focusedID.flatMap { displayForID($0) } ?? screens.displayIDs.first ?? 0
        let space   = activeSpace[display] ?? pseudoSpace(display)
        let tree    = ensureTree(space: space, display: display)

        if tree.workspaceFloat == nil {
            // A queued startup restore for this Space would later clobber the layout we're
            // about to stash as the float snapshot — drop it.
            pendingRestore.removeValue(forKey: space)
            let ids = tree.enterWorkspaceFloat()
            for id in ids {
                registry.setFloating(id, true)
                clearSlotBookkeeping(id, from: tree, newFocus: id)   // keep focus on the float
            }
            Log.logger.info("workspace float ON: floated \(ids.count) window(s) on space \(space)")
        } else {
            // Deterministic order so leftover insertion order is stable across runs.
            var returning: [WinID] = []
            for id in (tree.workspaceFloat?.floated ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let window = registry.window(for: id), registry.isFloating(id),
                      !registry.isMinimized(id) else { continue }   // closed/minimized while floating
                let (real, sticky) = resolveSpace(window, display: displayForID(id) ?? display)
                if sticky || real != space { continue }             // dragged away → stays a float there
                returning.append(id)
            }
            for id in returning { registry.setFloating(id, false) }
            tree.exitWorkspaceFloat(returning: returning,
                                    insertAt: InsertAt(rawValue: config.layout.insertAt) ?? .after,
                                    autoSplit: autoSplit, ratio: config.layout.defaultRatio)
            // Let the user's live focus win if it landed in the tree; else adopt the tree's
            // restored focus (cache only — never steal OS focus here).
            if let fid = focusedID, tree.contains(fid) {
                tree.focused = fid
            } else if let f = tree.focused {
                focusedID = f
            }
            Log.logger.info("workspace float OFF: tiled \(returning.count) window(s) on space \(space)")
        }
        retile(tree)
        notifyFocusOverlay(pulse: false)
    }

    func focusModeToggle() {
        // i3's mod+space (cycle focus between tiled/floating) — minimal: focus a floating
        // window if a tiled one is focused, else focus the focused tree's window.
        guard let fid = focusedID else { return }
        if registry.isFloating(fid) {
            if let (tiled, _) = preferredActiveFocus() { focus(windowID: tiled) }
        } else if let anyFloating = registry.floating.first {
            focus(windowID: anyFloating)
        }
    }

    func closeFocused() {
        guard let (fid, _) = activeTarget() else { return }
        registry.window(for: fid)?.close()   // destroyed notification cleans up the tree
    }

    // MARK: - Desktops (Spaces)

    /// Switch the focused window's display to its `index`-th user desktop (1-based). The
    /// resulting `activeSpaceDidChange` notification drives reconcile + refocus.
    func switchToDesktop(_ index: Int) {
        guard spaces.isAvailable else { return }
        let display = focusedDisplay()
        guard let ds = displayLayoutEntry(for: display),
              let target = userSpaceID(at: index, in: ds.spaces) else { return }
        spaces.setCurrentSpace(target, onDisplayUUID: ds.displayUUID)
    }

    /// Switch to the next (`step` = 1) or previous (`step` = -1) user desktop of the
    /// focused display, wrapping at the ends.
    func switchToDesktopRelative(_ step: Int) {
        guard spaces.isAvailable else { return }
        let display = focusedDisplay()
        guard let ds = displayLayoutEntry(for: display) else { return }
        let user = ds.spaces.filter { $0.isUser }
        guard user.count > 1, let cur = user.firstIndex(where: { $0.id == ds.currentSpace }) else { return }
        let count = user.count
        let target = user[((cur + step) % count + count) % count]
        spaces.setCurrentSpace(target.id, onDisplayUUID: ds.displayUUID)
    }

    /// i3's `workspace back_and_forth`: return to the desktop that was visible before
    /// the last switch on the focused display.
    func switchToDesktopBack() {
        guard spaces.isAvailable else { return }
        let display = focusedDisplay()
        guard let last = lastSpace[display],
              let ds = displayLayoutEntry(for: display),
              ds.spaces.contains(where: { $0.id == last && $0.isUser }) else { return }
        spaces.setCurrentSpace(last, onDisplayUUID: ds.displayUUID)
    }

    /// Send the focused window to the `index`-th user desktop (1-based) on its display.
    /// Closes the gap on the source; pre-sizes the destination. Follows only if configured.
    func moveFocusedToDesktop(_ index: Int) {
        guard spaces.isAvailable, let (fid, srcTree) = activeTarget(),
              let element = registry.window(for: fid)?.element,
              let wid = spaces.cgWindowID(for: element) else { return }
        let display = srcTree.display
        guard let ds = displayLayoutEntry(for: display),
              let target = userSpaceID(at: index, in: ds.spaces), target != srcTree.space else { return }

        spaces.moveWindow(wid, toSpace: target)           // window-server move (no AX frame change)
        detach(fid, from: srcTree)                         // clears zoom/focus/frame bookkeeping
        let dst = ensureTree(space: target, display: display)
        // A window sent onto a floating desktop floats there rather than tiling in — skip the
        // insert and the forced off-screen retile (nothing to size).
        if adoptIntoWorkspaceFloat(fid, tree: dst) { retile(srcTree); return }
        dst.insert(fid, focusedFrame: insertionHint(for: dst),
                   autoSplit: autoSplit, ratio: config.layout.defaultRatio)
        retile(srcTree)                                   // active source → gap closes
        retile(dst, force: true)                          // size it even though off-screen
        if config.layout.moveFollowsFocus { switchToDesktop(index) }
    }

    // MARK: - Gaps

    /// Runtime gaps tweak (`gaps inner +5` / `gaps outer -5`): applies immediately and
    /// lasts until `gaps reset` or a config reload — the file is never written.
    func adjustGaps(_ side: GapsSide, by delta: CGFloat) {
        var g = config.gaps
        switch side {
        case .inner: g.inner = max(0, g.inner + delta)
        case .outer: g.outer = max(0, g.outer + delta)
        }
        replaceGaps(g)
        retileAll()
    }

    /// Restore the config file's gaps (`gaps reset`).
    func resetGaps() {
        replaceGaps(baseGaps)
        retileAll()
    }

    // MARK: - Process / config

    func runExec(_ spec: String) {
        let command = config.exec[spec] ?? spec
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        do { try task.run() } catch { Log.logger.error("exec failed: \(command): \(error)") }
    }

    func reload() {
        do {
            replaceConfig(try ConfigLoader.load())
        } catch {
            // Keep the working config — a typo mid-edit must not wipe the live keybindings.
            Log.logger.error("config reload failed: \(error) — keeping the current config")
            onConfigError?("\(error)")
            return
        }
        keymap = Keymap(config: config)
        currentMode = Keymap.defaultMode
        applyKeymap()
        onConfigReloaded?(config)          // refresh the overlay's colors/metrics first…
        retileAll()                        // …then retile, which repositions the halo
        notifyFocusOverlay(pulse: false)   // reflect an enabled/disabled toggle immediately
        onConfigError?(nil)
        Log.logger.info("config reloaded")
    }

    func restart() { Relaunch.now() }

    // MARK: - Modes / debug

    func enterMode(_ name: String) {
        guard keymap.hasMode(name) else { return }
        currentMode = name
        applyKeymap()
        onModeChanged?(name)
    }

    func exitMode() {
        currentMode = Keymap.defaultMode
        applyKeymap()
        onModeChanged?(nil)
    }

    func dumpTree() {
        guard let fid = focusedID, let tree = treeContaining(fid) else { return }
        Log.logger.info("display \(tree.display) space \(tree.space)\(isActive(tree) ? " (active)" : "") focused=\(String(describing: tree.focused))\n\(tree.root?.describe() ?? "<empty>")")
    }
}
