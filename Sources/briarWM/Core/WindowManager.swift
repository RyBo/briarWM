import AppKit
import ApplicationServices

/// The orchestrator: owns one BSP tree per macOS Space (desktop), tracks windows/apps,
/// responds to AX events and hotkey-driven commands, and re-tiles. Everything runs on
/// the main thread, so no locking is needed.
///
/// The implementation is split across extension files by concern — `+Tabs` (native-tab
/// adoption), `+Commands` (everything the CommandRouter dispatches), `+Spaces` (desktop
/// reconciliation and display reconfiguration). One class, one shared state block below;
/// members are `internal` rather than `private` where an extension file needs them.
final class WindowManager: AXEventSink {
    /// Mutated only by `reload()` (in +Commands); everything else reads.
    private(set) var config: Config
    /// The gaps as loaded from the config file — what `gaps reset` restores after
    /// runtime `gaps inner/outer ±N` tweaks.
    private(set) var baseGaps: Gaps
    /// The config `auto_split` token as a typed enum — the single conversion point shared
    /// by every `BSPTree.insert` call site. `internal` so the +Commands/+Spaces extensions
    /// can read it. Falls back to `.longerEdge` for an unrecognized token (already flagged
    /// by `ConfigValidator`).
    var autoSplit: AutoSplit { AutoSplit(token: config.layout.autoSplit) ?? .longerEdge }
    let screens = ScreenManager()
    let registry = WindowRegistry()
    let hotkeys = HotkeyManager()
    let spaces = SpacesManager()

    var apps: [pid_t: AXApplication] = [:]
    /// One tree per Space. A Space belongs to exactly one display, so its `SpaceID` is a
    /// unique key; the tree also carries its `display` for geometry. When Space queries
    /// are unavailable, a per-display pseudo-Space (`pseudoSpace`) reproduces the old
    /// one-tree-per-display behavior.
    var trees: [SpaceID: BSPTree] = [:]
    /// Trees whose display vanished (monitor slept / unplugged / undocked). Their structure
    /// is preserved here — out of `trees`, so they never retile — and restored when the
    /// display returns (`screensChanged`). Their windows, which macOS relocates to a surviving
    /// display, are left untiled until then. This trades dormant windows during the outage for
    /// a faithful layout restore on reconnect, instead of destroying the layout on every blip.
    var parkedTrees: [BSPTree] = []
    /// The currently-visible Space on each display. Only trees whose Space is active
    /// have their frames applied to real windows.
    var activeSpace: [DisplayID: SpaceID] = [:]
    /// The previously-visible user desktop per display — the `workspace back_and_forth`
    /// target. Recorded by `refreshActiveSpaces` whenever the active Space changes,
    /// so switches made outside briarWM (Ctrl+arrows, Mission Control) count too.
    var lastSpace: [DisplayID: SpaceID] = [:]
    var desiredFrames: [WinID: CGRect] = [:]
    /// Windows seen on multiple Spaces once. Floating a window as "sticky" needs two
    /// consecutive observations — one transient multi-Space read (mid-animation, Mission
    /// Control) must not permanently pull a tiled window out of its tree.
    var stickyOnce: Set<WinID> = []
    /// Frames read once at the start of a `reconcileSpaces` pass, so tab dedup, tab
    /// matching, and frame application don't each re-read the same windows over AX
    /// (single-threaded, same tick — nothing moves between the snapshot and the writes
    /// at the end of the pass). nil outside a pass: every other retile path (commands,
    /// drag snap-back) must read live frames or snap-back breaks.
    var passFrames: [WinID: CGRect]?
    /// The window-server fingerprint from the last poll tick — `pollReconcile()` skips
    /// the full sweep when it hasn't changed.
    var lastPollSnapshot: WindowServerSnapshot?

    var keymap: Keymap
    var currentMode = Keymap.defaultMode
    var focusedID: WinID?
    var zoomedID: WinID?
    var router: CommandRouter!

    /// How far a tiled window may drift from its computed slot before it counts as a user
    /// drag (→ snap back). Kept above `Tiler.applyTolerance` so the notification from our
    /// own frame write landing never looks like a drag.
    private static let snapBackTolerance: CGFloat = 3

    /// Notified when the active mode changes (for the status item). nil = default mode.
    var onModeChanged: ((String?) -> Void)?
    /// Notified when a config reload fails (the error message) or succeeds again (nil),
    /// so the status item can show/clear a persistent error indicator.
    var onConfigError: ((String?) -> Void)?
    /// Hands the focus overlay the focused window's visible Cocoa frame (or nil = hide) and
    /// whether the focus target just changed (→ run the border pulse). See `focusOverlayFrame`.
    var onFocusOverlayUpdate: ((CGRect?, Bool) -> Void)?
    /// Fired after a successful config reload so the overlay picks up new colors/metrics.
    var onConfigReloaded: ((Config) -> Void)?

    init(config: Config) {
        self.config = config
        self.baseGaps = config.gaps
        self.keymap = Keymap(config: config)
    }

    /// The only full-config mutation point — used by `reload()` in +Commands
    /// (`private(set)` can't span extension files).
    func replaceConfig(_ newConfig: Config) {
        config = newConfig
        baseGaps = newConfig.gaps
    }

    /// Runtime gaps tweak (`gaps inner +5`): mutates the live config only; `baseGaps`
    /// keeps the file's values for `gaps reset`.
    func replaceGaps(_ gaps: Gaps) { config.gaps = gaps }

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

    /// Full re-sync after the machine wakes from sleep or the screen unlocks. Across those
    /// transitions the Space-change / app-activation notifications that normally drive
    /// tiling fire unreliably, and while locked the visible Space is the loginwindow Space
    /// — so re-read the active Spaces, re-home any windows that drifted, and re-apply every
    /// frame. Idempotent; safe to call on each wake/unlock notification.
    func resync() {
        refreshActiveSpaces()
        reconcileSpaces()
        retileAll()
        Log.logger.debug("resync after wake/unlock")
    }

    // MARK: - App tracking

    func addApp(pid: pid_t) {
        guard pid != getpid(), apps[pid] == nil else { return }
        let axApp = AXApplication(pid: pid, sink: self)
        apps[pid] = axApp
        axApp.start()
        var dirty: Set<SpaceID> = []
        reconcileApp(pid: pid, dirty: &dirty)   // tab-aware adopt/rebind/skip
        retile(dirty: dirty)
    }

    func removeApp(pid: pid_t) {
        guard let axApp = apps[pid] else { return }
        axApp.stop()
        apps.removeValue(forKey: pid)
        let tiled = allTrees.flatMap { $0.windowIDs }.filter { registry.window(for: $0)?.pid == pid }
        let floated = registry.floating.filter { registry.window(for: $0)?.pid == pid }
        var changed: Set<SpaceID> = []
        for id in tiled {
            if let tree = forget(id) { changed.insert(tree.space) }
        }
        floated.forEach { forget($0) }                             // floating windows must not leak either
        retile(dirty: changed)                                     // only active trees apply frames
    }

    // MARK: - Window adoption / filtering

    func considerWindow(_ element: AXUIElement, pid: pid_t, retile doRetile: Bool, focus: Bool = false) {
        guard registry.id(for: element) == nil else { return }
        let window = AXWindow(element: element, pid: pid)
        guard isTileable(window) else { return }
        let id = registry.register(window)

        if shouldFloat(window, pid: pid) {
            registry.setFloating(id, true)
            Log.logger.debug("float \(id) \(window.title ?? "?")")
            return
        }
        insertManaged(id: id, window: window, retile: doRetile, focus: focus)
    }

    /// Insert an already-registered, non-floating window into its current Space's tree and
    /// (optionally) retile. Sticky windows (spanning every desktop) are floated instead.
    /// Shared by `considerWindow` (first adoption) and `windowDeminimized` (restore from minimize).
    private func insertManaged(id: WinID, window: AXWindow, retile doRetile: Bool, focus: Bool) {
        let display = displayForWindow(window)
        let (space, sticky) = resolveSpace(window, display: display)
        if sticky {   // spans every desktop — can't live in a single tree.
            registry.setFloating(id, true)
            Log.logger.debug("float (sticky) \(id) \(window.title ?? "?")")
            return
        }
        let tree = ensureTree(space: space, display: display)
        let focusedFrame = insertionHint(for: tree) ?? window.frame
        tree.insert(id, focusedFrame: focusedFrame,
                    insertAt: InsertAt(rawValue: config.layout.insertAt) ?? .after,
                    autoSplit: autoSplit,
                    ratio: config.layout.defaultRatio)
        if focus { focusedID = id }
        Log.logger.debug("tile \(id) \(window.title ?? "?") on display \(display) space \(space)")
        if doRetile { retile(tree) }
    }

    func isTileable(_ window: AXWindow) -> Bool {
        guard window.subrole == (kAXStandardWindowSubrole as String) else { return false }
        if window.isMinimized || window.isFullscreen { return false }
        return window.isResizable
    }

    private func shouldFloat(_ window: AXWindow, pid: pid_t) -> Bool {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let title = window.title
        if let bundleID, config.floating.bundleIds.contains(bundleID) { return true }
        for rule in config.rules where rule.match.matches(bundleID: bundleID, title: title) {
            if let f = rule.floating { return f }
        }
        if let title {
            for pattern in config.floating.titleRegex where title.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Trees / displays

    @discardableResult
    func ensureTree(space: SpaceID, display: DisplayID) -> BSPTree {
        if let tree = trees[space] { return tree }
        let tree = BSPTree(display: display, space: space)
        trees[space] = tree
        return tree
    }

    /// Active trees only — what window *commands* (focus/move/resize) operate on. A parked
    /// tree's windows are dormant and must not be command targets.
    func treeContaining(_ id: WinID) -> BSPTree? { trees.values.first { $0.contains(id) } }

    /// Active *and* parked trees — for lifecycle cleanup (app quit, window destroyed), which
    /// must reach a window wherever it lives so closed windows don't leak from a parked tree.
    private var allTrees: [BSPTree] { Array(trees.values) + parkedTrees }
    private func anyTreeContaining(_ id: WinID) -> BSPTree? { allTrees.first { $0.contains(id) } }

    /// Remove every trace of a managed window: its leaf (in `tree`, or wherever it lives,
    /// parked trees included), registry entry, desired frame, zoom/focus/sticky references,
    /// and any parked tree the removal emptied. Returns the tree it was removed from so
    /// callers can retile. `newFocus` overrides the fallback focus (the tree's remembered one).
    /// Not for minimize — a minimized window must stay registered (`windowMinimized`).
    @discardableResult
    func forget(_ id: WinID, tree: BSPTree? = nil, newFocus: WinID? = nil) -> BSPTree? {
        let tree = tree ?? anyTreeContaining(id)
        if let tree {
            detach(id, from: tree, newFocus: newFocus)
        } else {                                        // not in any tree: still drop the bookkeeping
            desiredFrames.removeValue(forKey: id)
            stickyOnce.remove(id)
            if zoomedID == id { zoomedID = nil }
            if focusedID == id { focusedID = newFocus }
        }
        registry.unregister(id)
        pruneEmptyParkedTrees()
        return tree
    }

    /// Remove `id` from `tree` and drop the per-window tiling bookkeeping tied to its slot —
    /// desired frame, sticky observation, zoom — repointing focus to the tree's remembered
    /// window (or `newFocus`) when `id` was focused. The shared core of every "window leaves a
    /// tree" path (`forget`, `windowMinimized`, reconcile re-home/float); callers layer their
    /// own extra cleanup (registry unregister, minimize park, re-insert elsewhere) on top.
    func detach(_ id: WinID, from tree: BSPTree, newFocus: WinID? = nil) {
        tree.remove(id)
        desiredFrames.removeValue(forKey: id)
        stickyOnce.remove(id)
        if zoomedID == id { zoomedID = nil }
        if focusedID == id { focusedID = newFocus ?? tree.focused }
    }

    private func pruneEmptyParkedTrees() { parkedTrees.removeAll { $0.isEmpty } }

    /// Per-display pseudo-Space used when Space queries are unavailable: stable, unique,
    /// and always treated as active → identical to the old one-tree-per-display behavior.
    func pseudoSpace(_ display: DisplayID) -> SpaceID { SpaceID(display) }

    func isActive(_ tree: BSPTree) -> Bool { activeSpace[tree.display] == tree.space }

    /// Every non-floating window on a visible desktop, paired with its tree — what tab
    /// reconciliation and focus/move targeting iterate.
    func visibleTiledWindows() -> [(tree: BSPTree, id: WinID)] {
        var out: [(tree: BSPTree, id: WinID)] = []
        for tree in trees.values where isActive(tree) {
            for id in tree.windowIDs where !registry.isFloating(id) { out.append((tree, id)) }
        }
        return out
    }

    /// Desired frames restricted to windows on the visible desktops — the only windows
    /// that should be focus/move targets.
    func visibleFrames() -> [WinID: CGRect] {
        var out: [WinID: CGRect] = [:]
        for (_, id) in visibleTiledWindows() { if let f = desiredFrames[id] { out[id] = f } }
        return out
    }

    /// A window's on-screen frame: the pass snapshot when one is active (and holds the
    /// window), otherwise a live AX read.
    func currentFrame(_ id: WinID) -> CGRect? {
        passFrames?[id] ?? registry.window(for: id)?.frame
    }

    private func displayForWindow(_ window: AXWindow) -> DisplayID {
        if let frame = window.frame, let display = screens.displayForAXRect(frame) { return display }
        return screens.displayIDs.first ?? 0
    }

    func displayForID(_ id: WinID) -> DisplayID? {
        if let tree = treeContaining(id) { return tree.display }              // authoritative for tiled
        if let frame = registry.window(for: id)?.frame { return screens.displayForAXRect(frame) }
        return nil
    }

    /// The display of the focused window, falling back to the first display (id 0 if none).
    /// The default target for desktop-switch commands with nothing focused.
    func focusedDisplay() -> DisplayID {
        focusedID.flatMap { treeContaining($0)?.display } ?? screens.displayIDs.first ?? 0
    }

    /// The frame to seed a newly-inserted leaf's split from: the tree's focused window's
    /// desired frame, if any. nil when the tree is empty or its focus has no recorded frame —
    /// the caller supplies a fallback (the window's own frame) or lets `BSPTree.insert` pick.
    func insertionHint(for tree: BSPTree) -> CGRect? { tree.focused.flatMap { desiredFrames[$0] } }

    // MARK: - Tiling

    func retileAll() { trees.values.forEach { retile($0) } }

    /// Retile just the Spaces a change dirtied. Skips any that have no tree.
    func retile(dirty: Set<SpaceID>) {
        for s in dirty { if let t = trees[s] { retile(t) } }
    }

    /// Retile the given Spaces plus every visible one — the visible pass applies frames
    /// that were only computed while their desktop was hidden (e.g. a window that
    /// arrived off-screen).
    func retileDirtyAndVisible(_ dirty: Set<SpaceID>) {
        var toRetile = dirty
        for tree in trees.values where isActive(tree) { toRetile.insert(tree.space) }
        toRetile.forEach { if let t = trees[$0] { retile(t) } }
    }

    /// Recompute `tree`'s frames and record them. Apply them to real windows only when
    /// the tree's Space is currently visible (`isActive`) — or `force`d, used to pre-size
    /// a destination desktop after a move. This is the core per-Space invariant: AX
    /// `setFrame` never touches windows on a hidden desktop.
    func retile(_ tree: BSPTree, force: Bool = false) {
        guard let screen = screens.screen(for: tree.display) else { return }
        let area = screens.tilingAreaAX(for: screen, outerGap: config.gaps.outer)
        var frames = LayoutEngine.computeFrames(root: tree.root, area: area, innerGap: config.gaps.inner)
        if let z = zoomedID, tree.contains(z) { frames[z] = area }   // fullscreen override
        for (id, rect) in frames { desiredFrames[id] = rect }
        guard isActive(tree) || force else { return }
        Tiler.apply(frames, registry: registry, current: passFrames)
        if let z = zoomedID, tree.contains(z) { registry.window(for: z)?.raise() }
        // Keep the halo tracking the focused window's new slot on resize/move/reflow.
        if let fid = focusedID, tree.contains(fid) { notifyFocusOverlay(pulse: false) }
    }

    // MARK: - AXEventSink

    func windowCreated(_ element: AXUIElement, pid: pid_t) {
        var dirty: Set<SpaceID> = []
        reconcileApp(pid: pid, dirty: &dirty)   // adopt OR rebind OR ignore
        if let id = registry.id(for: element) { setFocused(id) }        // nil ⇒ ignored background tab
        retile(dirty: dirty)
    }

    func windowDestroyed(_ element: AXUIElement, pid: pid_t) {
        guard let id = registry.id(for: element) else { return }   // misdirected destroy → poll reap handles it
        // A native tab close where a sibling is promoted to front: keep the tile, show the
        // sibling (rebind) instead of collapsing the layout.
        if !registry.isFloating(id), let tree = treeContaining(id), isActive(tree),
           let promoted = promotedTabSibling(forClosing: id, pid: pid) {
            registry.rebind(id, to: promoted, pid: pid)
            apps[pid]?.observe(window: promoted)
            focusedID = id
            tree.focused = id
            Log.logger.debug("tab close rebind \(id) → promoted sibling")
            retile(tree)
            return
        }
        let tree = forget(id)                          // could be parked (its monitor is asleep)
        if let tree { retile(tree) }                   // no-op for a parked tree (display gone)
        notifyFocusOverlay(pulse: false)               // hide/reposition after focus fell away
    }

    /// A tiled window was minimized: remove it from its tree and reflow the rest so no empty
    /// slot is left (like a close, but the window stays registered and parked in
    /// `registry.minimized` for `windowDeminimized` to restore). Gated by `reflow_on_minimize`.
    func windowMinimized(_ element: AXUIElement, pid: pid_t) {
        guard config.layout.reflowOnMinimize else { return }
        guard let id = registry.id(for: element), !registry.isFloating(id) else { return }
        guard let tree = anyTreeContaining(id) else { return }   // already out of a tree → nothing to do
        detach(id, from: tree)                         // drops the stale desired frame too
        registry.setMinimized(id, true)
        pruneEmptyParkedTrees()
        Log.logger.debug("minimize park \(id)")
        retile(tree)
    }

    /// A window was un-minimized: re-insert it into its current Space's tree and reflow.
    /// A window we never managed (created minimized, or reflow was off when it minimized)
    /// hits the `id == nil` branch and is adopted fresh.
    func windowDeminimized(_ element: AXUIElement, pid: pid_t) {
        guard let id = registry.id(for: element) else {
            considerWindow(element, pid: pid, retile: true, focus: true)
            return
        }
        guard registry.isMinimized(id) else { return }   // not one we parked (e.g. a floating window)
        registry.setMinimized(id, false)
        guard let window = registry.window(for: id) else { return }
        Log.logger.debug("deminimize restore \(id)")
        insertManaged(id: id, window: window, retile: true, focus: true)
    }

    func focusChanged(pid: pid_t) { refreshFocus(pid: pid) }
    func appActivated(pid: pid_t) { refreshFocus(pid: pid) }

    /// Update the focus cache from an app's AX-focused window. Fast path (cache-only, no CG
    /// call) when that window is already managed. When it isn't — a switch to a background tab
    /// — reconcile the app first so the tab group's leaf rebinds to the now-front element, then
    /// read the id back. Never steals OS focus.
    private func refreshFocus(pid: pid_t) {
        guard let focused = apps[pid]?.focusedWindow() else { return }
        if let id = registry.id(for: focused) { setFocused(id); return }
        guard manageTabs else { return }
        // A switch to a background tab: reconcile so the group's leaf rebinds to the now-front
        // tab, then adopt the resulting focus.
        var dirty: Set<SpaceID> = []
        reconcileApp(pid: pid, dirty: &dirty)
        if let id = registry.id(for: focused) { setFocused(id) }    // now == the rebound leaf
        retile(dirty: dirty)
    }

    func windowMovedOrResized(_ element: AXUIElement, pid: pid_t) {
        guard let id = registry.id(for: element), !registry.isFloating(id), zoomedID != id else { return }
        guard let tree = treeContaining(id),
              let desired = desiredFrames[id],
              let current = registry.window(for: id)?.frame else { return }
        // If a tiled window drifted from its computed slot, the user dragged it: snap back.
        if !rectsApproxEqual(current, desired, Self.snapBackTolerance) { retile(tree) }
    }

    // MARK: - Focus

    /// Keep `focusedID` pointing at a window on a visible desktop. When the cache is already
    /// valid this is a no-op; otherwise it adopts the deterministic `preferredActiveFocus()`.
    /// Cache-only unless `moveFocus` (a genuine user Space switch) — so the backstop poll,
    /// app activation and display reconfig repair the cache without yanking OS focus. This
    /// also rescues a `focusedID` left pointing at a *parked* window (the old reassert no-op'd
    /// there because `treeContaining` skips parked trees).
    func repairFocusCache(moveFocus: Bool) {
        if let fid = focusedID, let tree = treeContaining(fid), isActive(tree) { return }
        guard let (id, tree) = preferredActiveFocus() else { return }
        Log.logger.debug("focus repair: \(String(describing: focusedID)) → \(id) on display \(tree.display) space \(tree.space) [moveFocus=\(moveFocus)]")
        if moveFocus { focus(windowID: id) } else { setFocused(id) }
    }

    /// Update the focus cache without touching OS keyboard focus.
    func setFocused(_ id: WinID) {
        let changed = focusedID != id
        focusedID = id
        treeContaining(id)?.focused = id
        notifyFocusOverlay(pulse: changed)   // pulse only on a real focus switch
    }

    // MARK: - Focus overlay

    /// The focused window's visible frame in **Cocoa** coordinates (the overlay's drawing
    /// space), or nil when the overlay must hide: indicator disabled, nothing focused, the
    /// focus is on a hidden/parked desktop, or it's a fullscreen/zoomed window (no border on
    /// something already filling the screen). Floating windows resolve to their live AX frame.
    private func focusOverlayFrame() -> CGRect? {
        guard config.focusIndicator.enabled, let id = focusedID,
              let tree = treeContaining(id), isActive(tree) else { return nil }
        if id == zoomedID || registry.window(for: id)?.isFullscreen == true { return nil }
        guard let ax = desiredFrames[id] ?? registry.window(for: id)?.frame else { return nil }
        return Geometry.cocoaToAX(ax, primaryHeight: screens.primaryHeight)   // AX ⇄ Cocoa (self-inverse)
    }

    /// Push the current overlay state to the controller. `pulse` runs the border fade (real
    /// focus switch); position-only follows (retile/resize/Space change) pass `pulse: false`.
    func notifyFocusOverlay(pulse: Bool) { onFocusOverlayUpdate?(focusOverlayFrame(), pulse) }

    /// The window a focus recovery should land on, chosen deterministically: the frontmost
    /// app's AX-focused window if it's tiled on an active tree (what the user is really
    /// looking at), else the active focus-remembering tree with the lowest `(display, space)`.
    /// Deterministic ordering matters because `trees` is a Dictionary — `first(where:)` would
    /// otherwise pick an arbitrary display.
    func preferredActiveFocus() -> (WinID, BSPTree)? {
        if let app = NSWorkspace.shared.frontmostApplication,
           let element = apps[app.processIdentifier]?.focusedWindow(),
           let id = registry.id(for: element),
           let tree = treeContaining(id), isActive(tree) {
            return (id, tree)
        }
        let candidates = trees.values
            .filter { isActive($0) && $0.focused != nil }
            .sorted { ($0.display, $0.space) < ($1.display, $1.space) }
        if let tree = candidates.first, let id = tree.focused { return (id, tree) }
        return nil
    }

    /// The (window, tree) a "focused" command should act on, guaranteed to be on a visible
    /// Space. `focusedID` is a cache fed by AX focus events, which fire unreliably across
    /// desktop switches — so when it points at a hidden tree we re-derive focus from the
    /// active Space instead of silently editing the wrong desktop. Self-heals the cache.
    func activeTarget() -> (WinID, BSPTree)? {
        if let fid = focusedID, let tree = treeContaining(fid), isActive(tree) {
            return (fid, tree)                                   // cache valid & visible
        }
        refreshActiveSpaces()
        if let (id, tree) = preferredActiveFocus() {
            setFocused(id)                                       // self-heal the cache
            return (id, tree)
        }
        return nil
    }

    /// Assert OS keyboard focus onto a managed window (and update the cache).
    func focus(windowID id: WinID) {
        guard let window = registry.window(for: id) else { return }
        setFocused(id)
        // Bring the target's process frontmost and make its window key. On macOS 14+ this
        // SkyLight path is the only reliable cross-app focus transfer; activate() is only a
        // fallback for when the private symbols are unavailable (and is itself unreliable).
        if !spaces.raiseAndFocus(window.element, pid: window.pid) {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
        }
        window.focus()   // AX: mark the window main/focused and raise within its app
    }
}
