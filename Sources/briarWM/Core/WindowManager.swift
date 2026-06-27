import AppKit
import ApplicationServices

/// The orchestrator: owns one BSP tree per macOS Space (desktop), tracks windows/apps,
/// responds to AX events and hotkey-driven commands, and re-tiles. Everything runs on
/// the main thread, so no locking is needed.
final class WindowManager: AXEventSink {
    private(set) var config: Config
    private let screens = ScreenManager()
    private let registry = WindowRegistry()
    private let hotkeys = HotkeyManager()
    private let spaces = SpacesManager()

    private var apps: [pid_t: AXApplication] = [:]
    /// One tree per Space. A Space belongs to exactly one display, so its `SpaceID` is a
    /// unique key; the tree also carries its `display` for geometry. When Space queries
    /// are unavailable, a per-display pseudo-Space (`pseudoSpace`) reproduces the old
    /// one-tree-per-display behavior.
    private var trees: [SpaceID: BSPTree] = [:]
    /// The currently-visible Space on each display. Only trees whose Space is active
    /// have their frames applied to real windows.
    private var activeSpace: [DisplayID: SpaceID] = [:]
    private var desiredFrames: [WinID: CGRect] = [:]

    private var keymap: Keymap
    private var currentMode = Keymap.defaultMode
    private var focusedID: WinID?
    private var zoomedID: WinID?
    private var router: CommandRouter!

    /// Notified when the active mode changes (for the status item). nil = default mode.
    var onModeChanged: ((String?) -> Void)?

    init(config: Config) {
        self.config = config
        self.keymap = Keymap(config: config)
    }

    // MARK: - Lifecycle

    func start() {
        router = CommandRouter(manager: self)
        hotkeys.install { [weak self] combo in self?.handleHotkey(combo) }
        refreshActiveSpaces()
        for d in screens.displayIDs { ensureTree(space: activeSpace[d] ?? pseudoSpace(d), display: d) }
        applyKeymap()
        adoptExistingWindows()
        retileAll()
        let tiled = trees.values.reduce(0) { $0 + $1.windowIDs.count }
        Log.logger.info("briarWM started: \(tiled) tiled, \(registry.floating.count) floating, \(screens.displayIDs.count) display(s), \(trees.count) desktop tree(s)")
    }

    private func adoptExistingWindows() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            addApp(pid: app.processIdentifier)
        }
    }

    /// Adopt standard windows that exist but aren't tracked yet — typically windows that
    /// lived on a non-active Space when briarWM launched (AX's per-app window list omits
    /// off-Space windows, so the startup scan never saw them) and only became enumerable
    /// once their desktop was activated. Idempotent and cheap; runs on the reconcile
    /// cadence. Never steals focus (`considerWindow` defaults `focus: false`).
    private func discoverWindows() {
        for (pid, app) in apps {
            for element in app.windows() where registry.id(for: element) == nil {
                considerWindow(element, pid: pid, retile: true)
                if registry.id(for: element) != nil { app.observe(window: element) }
            }
        }
    }

    // MARK: - App tracking

    func addApp(pid: pid_t) {
        guard pid != getpid(), apps[pid] == nil else { return }
        let axApp = AXApplication(pid: pid, sink: self)
        apps[pid] = axApp
        axApp.start()
        var changed: Set<SpaceID> = []
        for element in axApp.windows() where registry.id(for: element) == nil {
            considerWindow(element, pid: pid, retile: false)
            if let id = registry.id(for: element), let tree = treeContaining(id) { changed.insert(tree.space) }
        }
        changed.forEach { if let t = trees[$0] { retile(t) } }
    }

    func removeApp(pid: pid_t) {
        guard let axApp = apps[pid] else { return }
        axApp.stop()
        apps.removeValue(forKey: pid)
        let ids = trees.values.flatMap { $0.windowIDs }.filter { registry.window(for: $0)?.pid == pid }
        var changed: Set<SpaceID> = []
        for id in ids {
            if let tree = treeContaining(id) { tree.remove(id); changed.insert(tree.space) }
            registry.unregister(id)
            desiredFrames.removeValue(forKey: id)
        }
        changed.forEach { if let t = trees[$0] { retile(t) } }
    }

    // MARK: - Window adoption / filtering

    private func considerWindow(_ element: AXUIElement, pid: pid_t, retile doRetile: Bool, focus: Bool = false) {
        guard registry.id(for: element) == nil else { return }
        let window = AXWindow(element: element, pid: pid)
        guard isTileable(window) else { return }
        let id = registry.register(window)

        if shouldFloat(window, pid: pid) {
            registry.setFloating(id, true)
            Log.logger.debug("float \(id) \(window.title ?? "?")")
            return
        }

        let display = displayForWindow(window)
        let (space, sticky) = resolveSpace(window, display: display)
        if sticky {   // spans every desktop — can't live in a single tree.
            registry.setFloating(id, true)
            Log.logger.debug("float (sticky) \(id) \(window.title ?? "?")")
            return
        }
        let tree = ensureTree(space: space, display: display)
        let focusedFrame = tree.focused.flatMap { desiredFrames[$0] } ?? window.frame
        tree.insert(id, focusedFrame: focusedFrame,
                    insertAt: InsertAt(rawValue: config.layout.insertAt) ?? .after,
                    autoSplit: config.layout.autoSplit)
        if focus { focusedID = id }
        Log.logger.debug("tile \(id) \(window.title ?? "?") on display \(display) space \(space)")
        if doRetile { retile(tree) }
    }

    private func isTileable(_ window: AXWindow) -> Bool {
        guard window.subrole == (kAXStandardWindowSubrole as String) else { return false }
        if window.isMinimized || window.isFullscreen { return false }
        return window.isResizable
    }

    private func shouldFloat(_ window: AXWindow, pid: pid_t) -> Bool {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if let bundleID {
            if config.floating.bundleIds.contains(bundleID) { return true }
            for rule in config.rules where rule.match.bundleId == bundleID {
                if let f = rule.floating { return f }
            }
        }
        if let title = window.title {
            for pattern in config.floating.titleRegex where title.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Trees / displays / Spaces

    @discardableResult
    private func ensureTree(space: SpaceID, display: DisplayID) -> BSPTree {
        if let tree = trees[space] { return tree }
        let tree = BSPTree(display: display, space: space)
        trees[space] = tree
        return tree
    }

    private func treeContaining(_ id: WinID) -> BSPTree? { trees.values.first { $0.contains(id) } }

    /// Per-display pseudo-Space used when Space queries are unavailable: stable, unique,
    /// and always treated as active → identical to the old one-tree-per-display behavior.
    private func pseudoSpace(_ display: DisplayID) -> SpaceID { SpaceID(display) }

    private func isActive(_ tree: BSPTree) -> Bool { activeSpace[tree.display] == tree.space }

    /// Resolve the desktop a window currently lives on. `sticky` ⇒ it spans multiple
    /// Spaces (treat as floating). Falls back to the display's pseudo-Space.
    private func resolveSpace(_ window: AXWindow, display: DisplayID) -> (space: SpaceID, sticky: Bool) {
        guard spaces.isAvailable, let wid = spaces.cgWindowID(for: window.element) else {
            return (pseudoSpace(display), false)
        }
        let ids = spaces.spaceIDs(for: wid)
        if ids.count > 1 { return (pseudoSpace(display), true) }
        return (ids.first ?? pseudoSpace(display), false)
    }

    /// Refresh the visible Space per display from the window server (or pseudo-Spaces).
    private func refreshActiveSpaces() {
        if spaces.isAvailable {
            for ds in spaces.displayLayout() {
                if let d = ds.displayID { activeSpace[d] = ds.currentSpace }
            }
        }
        for d in screens.displayIDs where activeSpace[d] == nil { activeSpace[d] = pseudoSpace(d) }
    }

    /// Desired frames restricted to windows on the visible desktops — the only windows
    /// that should be focus/move targets.
    private func visibleFrames() -> [WinID: CGRect] {
        var out: [WinID: CGRect] = [:]
        for tree in trees.values where isActive(tree) {
            for id in tree.windowIDs { if let f = desiredFrames[id] { out[id] = f } }
        }
        return out
    }

    private func displayForWindow(_ window: AXWindow) -> DisplayID {
        if let frame = window.frame, let display = screens.displayForAXRect(frame) { return display }
        return screens.displayIDs.first ?? 0
    }

    private func displayForID(_ id: WinID) -> DisplayID? {
        if let tree = treeContaining(id) { return tree.display }              // authoritative for tiled
        if let frame = registry.window(for: id)?.frame { return screens.displayForAXRect(frame) }
        return nil
    }

    // MARK: - Tiling

    func retileAll() { trees.values.forEach { retile($0) } }

    /// Recompute `tree`'s frames and record them. Apply them to real windows only when
    /// the tree's Space is currently visible (`isActive`) — or `force`d, used to pre-size
    /// a destination desktop after a move. This is the core per-Space invariant: AX
    /// `setFrame` never touches windows on a hidden desktop.
    private func retile(_ tree: BSPTree, force: Bool = false) {
        guard let screen = screens.screen(for: tree.display) else { return }
        let area = screens.tilingAreaAX(for: screen, outerGap: config.gaps.outer)
        var frames = LayoutEngine.computeFrames(root: tree.root, area: area, innerGap: config.gaps.inner)
        if let z = zoomedID, tree.contains(z) { frames[z] = area }   // fullscreen override
        for (id, rect) in frames { desiredFrames[id] = rect }
        guard isActive(tree) || force else { return }
        Tiler.apply(frames, registry: registry)
        if let z = zoomedID, tree.contains(z) { registry.window(for: z)?.raise() }
    }

    // MARK: - AXEventSink

    func windowCreated(_ element: AXUIElement, pid: pid_t) {
        considerWindow(element, pid: pid, retile: true, focus: true)
    }

    func windowDestroyed(_ element: AXUIElement, pid: pid_t) {
        guard let id = registry.id(for: element) else { return }
        let tree = treeContaining(id)
        tree?.remove(id)
        registry.unregister(id)
        desiredFrames.removeValue(forKey: id)
        if zoomedID == id { zoomedID = nil }
        if focusedID == id { focusedID = tree?.focused }
        if let tree { retile(tree) }
    }

    func focusChanged(pid: pid_t) {
        guard let focused = apps[pid]?.focusedWindow(), let id = registry.id(for: focused) else { return }
        focusedID = id
        treeContaining(id)?.focused = id
    }

    func windowMovedOrResized(_ element: AXUIElement, pid: pid_t) {
        guard let id = registry.id(for: element), !registry.isFloating(id), zoomedID != id else { return }
        guard let tree = treeContaining(id),
              let desired = desiredFrames[id],
              let current = registry.window(for: id)?.frame else { return }
        // If a tiled window drifted from its computed slot, the user dragged it: snap back.
        if !rectsApproxEqual(current, desired, 3) { retile(tree) }
    }

    func appActivated(pid: pid_t) {
        guard let focused = apps[pid]?.focusedWindow(), let id = registry.id(for: focused) else { return }
        focusedID = id
        treeContaining(id)?.focused = id
    }

    func screensChanged() {
        screens.refresh()
        refreshActiveSpaces()
        let valid = Set(screens.displayIDs)
        let primary = screens.displayIDs.first ?? 0
        let primaryTree = ensureTree(space: activeSpace[primary] ?? pseudoSpace(primary), display: primary)
        // Evacuate trees whose display is gone into the primary's active desktop.
        // (Snapshot first — we mutate `trees` in the loop.)
        let orphaned = trees.filter { !valid.contains($0.value.display) }
        for (space, tree) in orphaned {
            for id in tree.windowIDs { primaryTree.insert(id, focusedFrame: nil) }
            trees.removeValue(forKey: space)
        }
        reconcileSpaces()
        retileAll()
    }

    // MARK: - Hotkeys

    private func handleHotkey(_ combo: KeyCombo) {
        guard let action = keymap.action(for: combo, mode: currentMode) else { return }
        Log.logger.debug("action \(String(describing: action)) [mode=\(currentMode)]")
        router.perform(action)
    }

    private func applyKeymap() {
        hotkeys.setHotkeys(keymap.combos(for: currentMode))
    }

    // MARK: - Commands

    func focusDirection(_ dir: Direction) {
        guard let (fid, tree) = activeTarget() else { return }
        let visible = visibleFrames()
        let frames = config.layout.focusWrapsMonitors
            ? visible
            : visible.filter { treeContaining($0.key)?.display == tree.display }
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
            tree.remove(fid)
            targetTree.insert(fid, focusedFrame: desiredFrames[target])
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
            tree.insert(fid, focusedFrame: tree.focused.flatMap { desiredFrames[$0] })
            retile(tree)
        } else if let tree = treeContaining(fid) {
            tree.remove(fid)
            registry.setFloating(fid, true)
            retile(tree)
        }
    }

    func focusModeToggle() {
        // i3's mod+space (cycle focus between tiled/floating) — minimal: focus a floating
        // window if a tiled one is focused, else focus the focused tree's window.
        guard let fid = focusedID else { return }
        if registry.isFloating(fid) {
            if let tiled = trees.values.first(where: { isActive($0) && $0.focused != nil })?.focused { focus(windowID: tiled) }
        } else if let anyFloating = registry.floating.first {
            focus(windowID: anyFloating)
        }
    }

    func closeFocused() {
        guard let (fid, _) = activeTarget() else { return }
        registry.window(for: fid)?.close()   // destroyed notification cleans up the tree
    }

    func runExec(_ spec: String) {
        let command = config.exec[spec] ?? spec
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        do { try task.run() } catch { Log.logger.error("exec failed: \(command): \(error)") }
    }

    func reload() {
        config = ConfigLoader.load()
        keymap = Keymap(config: config)
        currentMode = Keymap.defaultMode
        applyKeymap()
        retileAll()
        Log.logger.info("config reloaded")
    }

    func restart() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        proc.arguments = Array(CommandLine.arguments.dropFirst())
        try? proc.run()
        NSApp.terminate(nil)
    }

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

    // MARK: - Spaces (desktops)

    /// Re-home every managed window whose real Space no longer matches the tree it's in,
    /// then re-tile the visible desktops. Active trees apply frames — closing the gap on
    /// the source desktop and sizing windows on the destination; hidden trees only
    /// recompute. No-op without Space support. Cheap enough for the backstop timer.
    func reconcileSpaces() {
        discoverWindows()   // pick up windows whose Space was hidden (off AX's list) at startup
        guard spaces.isAvailable else { return }
        refreshActiveSpaces()

        // space → owning display, from the current layout.
        var spaceDisplay: [SpaceID: DisplayID] = [:]
        for ds in spaces.displayLayout() {
            guard let d = ds.displayID else { continue }
            for s in ds.spaces { spaceDisplay[s.id] = d }
        }

        var dirty: Set<SpaceID> = []
        for tree in Array(trees.values) {                 // snapshot: we mutate `trees`
            for id in tree.windowIDs where !registry.isFloating(id) {
                guard let element = registry.window(for: id)?.element,
                      let wid = spaces.cgWindowID(for: element) else { continue }
                let ids = spaces.spaceIDs(for: wid)
                if ids.count > 1 {                        // became sticky → float it
                    tree.remove(id)
                    registry.setFloating(id, true)
                    if focusedID == id { focusedID = tree.focused }
                    dirty.insert(tree.space)
                    continue
                }
                guard let real = ids.first, real != tree.space else { continue }
                // If this fires every tick for windows you never moved, the window-server's
                // window→Space numbering disagrees with the managed-space dict key — see
                // SpacesManager.spaceID(from:) and switch the preferred key.
                Log.logger.debug("reconcile: \(id) moved space \(tree.space) → \(real)")
                tree.remove(id)
                let dst = ensureTree(space: real, display: spaceDisplay[real] ?? tree.display)
                dst.insert(id, focusedFrame: dst.focused.flatMap { desiredFrames[$0] })
                if focusedID == id { focusedID = tree.focused }
                dirty.insert(tree.space)
                dirty.insert(real)
            }
        }

        // Retile changed trees plus every visible one (to apply frames that were only
        // computed while their desktop was hidden, e.g. a window that arrived off-screen).
        var toRetile = dirty
        for tree in trees.values where isActive(tree) { toRetile.insert(tree.space) }
        toRetile.forEach { if let t = trees[$0] { retile(t) } }
        reassertFocusOnActiveDesktop()
    }

    /// Switch the focused window's display to its `index`-th user desktop (1-based). The
    /// resulting `activeSpaceDidChange` notification drives reconcile + refocus.
    func switchToDesktop(_ index: Int) {
        guard spaces.isAvailable else { return }
        let display = focusedID.flatMap { treeContaining($0)?.display } ?? screens.displayIDs.first ?? 0
        guard let ds = spaces.displayLayout().first(where: { $0.displayID == display }),
              let target = userSpaceID(at: index, in: ds.spaces) else { return }
        spaces.setCurrentSpace(target, onDisplayUUID: ds.displayUUID)
    }

    /// Send the focused window to the `index`-th user desktop (1-based) on its display.
    /// Closes the gap on the source; pre-sizes the destination. Follows only if configured.
    func moveFocusedToDesktop(_ index: Int) {
        guard spaces.isAvailable, let (fid, srcTree) = activeTarget(),
              let element = registry.window(for: fid)?.element,
              let wid = spaces.cgWindowID(for: element) else { return }
        let display = srcTree.display
        guard let ds = spaces.displayLayout().first(where: { $0.displayID == display }),
              let target = userSpaceID(at: index, in: ds.spaces), target != srcTree.space else { return }

        spaces.moveWindow(wid, toSpace: target)           // window-server move (no AX frame change)
        srcTree.remove(fid)
        if focusedID == fid { focusedID = srcTree.focused }
        let dst = ensureTree(space: target, display: display)
        dst.insert(fid, focusedFrame: dst.focused.flatMap { desiredFrames[$0] })
        retile(srcTree)                                   // active source → gap closes
        retile(dst, force: true)                          // size it even though off-screen
        if config.layout.moveFollowsFocus { switchToDesktop(index) }
    }

    /// If the focused window sits on a now-hidden desktop, move focus to a visible one.
    private func reassertFocusOnActiveDesktop() {
        guard let fid = focusedID, let tree = treeContaining(fid), !isActive(tree) else { return }
        if let active = trees.values.first(where: { isActive($0) && $0.focused != nil }),
           let target = active.focused {
            focus(windowID: target)
        }
    }

    /// The (window, tree) a "focused" command should act on, guaranteed to be on a visible
    /// Space. `focusedID` is a cache fed by AX focus events, which fire unreliably across
    /// desktop switches — so when it points at a hidden tree we re-derive focus from the
    /// active Space instead of silently editing the wrong desktop. Self-heals the cache.
    private func activeTarget() -> (WinID, BSPTree)? {
        if let fid = focusedID, let tree = treeContaining(fid), isActive(tree) {
            return (fid, tree)                                   // cache valid & visible
        }
        refreshActiveSpaces()
        // The window the user is really looking at: the frontmost app's AX-focused window,
        // if it is tiled on a now-active Space.
        if let app = NSWorkspace.shared.frontmostApplication,
           let element = apps[app.processIdentifier]?.focusedWindow(),
           let id = registry.id(for: element),
           let tree = treeContaining(id), isActive(tree) {
            focusedID = id
            tree.focused = id
            return (id, tree)
        }
        // Fall back to a visible tree's remembered focus.
        if let tree = trees.values.first(where: { isActive($0) && $0.focused != nil }),
           let id = tree.focused {
            focusedID = id
            return (id, tree)
        }
        return nil
    }

    // MARK: - Focus helper

    private func focus(windowID id: WinID) {
        guard let window = registry.window(for: id) else { return }
        focusedID = id
        treeContaining(id)?.focused = id
        window.focus()
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateIgnoringOtherApps])
    }
}
