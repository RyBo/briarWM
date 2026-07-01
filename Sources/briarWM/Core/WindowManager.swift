import AppKit
import ApplicationServices

/// What to do with an untracked window encountered during tab-aware adoption.
enum AdoptDecision: Equatable {
    case adopt            // a genuine standalone window → tile it
    case rebind(WinID)    // the front tab of an existing group → re-point that leaf in place
    case ignore           // a background tab on the visible desktop → never tile it
}

/// Pure tab-adoption decision. A window NOT stacked on an existing same-app tile
/// (`frameMatch == nil`) is a standalone/first window → adopt. One that IS stacked is a native
/// tab of that group: take over the leaf if this window is the app's front (focused) tab and the
/// leaf isn't already claimed this pass; otherwise it's a background tab → ignore.
func tabDecision(frameMatch: WinID?, isFront: Bool, leafAlreadyUsed: Bool) -> AdoptDecision {
    guard let leaf = frameMatch else { return .adopt }
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
    /// Trees whose display vanished (monitor slept / unplugged / undocked). Their structure
    /// is preserved here — out of `trees`, so they never retile — and restored when the
    /// display returns (`screensChanged`). Their windows, which macOS relocates to a surviving
    /// display, are left untiled until then. This trades dormant windows during the outage for
    /// a faithful layout restore on reconnect, instead of destroying the layout on every blip.
    private var parkedTrees: [BSPTree] = []
    /// The currently-visible Space on each display. Only trees whose Space is active
    /// have their frames applied to real windows.
    private var activeSpace: [DisplayID: SpaceID] = [:]
    private var desiredFrames: [WinID: CGRect] = [:]
    /// Windows seen on multiple Spaces once. Floating a window as "sticky" needs two
    /// consecutive observations — one transient multi-Space read (mid-animation, Mission
    /// Control) must not permanently pull a tiled window out of its tree.
    private var stickyOnce: Set<WinID> = []

    private var keymap: Keymap
    private var currentMode = Keymap.defaultMode
    private var focusedID: WinID?
    private var zoomedID: WinID?
    private var router: CommandRouter!

    /// Notified when the active mode changes (for the status item). nil = default mode.
    var onModeChanged: ((String?) -> Void)?
    /// Notified when a config reload fails (the error message) or succeeds again (nil),
    /// so the status item can show/clear a persistent error indicator.
    var onConfigError: ((String?) -> Void)?

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
        dirty.forEach { if let t = trees[$0] { retile(t) } }
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
        changed.forEach { if let t = trees[$0] { retile(t) } }     // only active trees apply frames
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
        let focusedFrame = tree.focused.flatMap { desiredFrames[$0] } ?? window.frame
        tree.insert(id, focusedFrame: focusedFrame,
                    insertAt: InsertAt(rawValue: config.layout.insertAt) ?? .after,
                    autoSplit: config.layout.autoSplit,
                    ratio: config.layout.defaultRatio)
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

    // MARK: - Tab-aware adoption

    private var manageTabs: Bool { config.layout.manageTabbedWindows }
    /// How close two windows' frames must be to count as "stacked" — i.e. native tabs of one
    /// group, which share the exact same frame (0px). Kept tight so it tolerates rounding but
    /// stays well below macOS's ~20px cascade offset for genuinely *separate* new windows.
    private static let tabStackTolerance: CGFloat = 10
    /// How far a tiled window may drift from its computed slot before it counts as a user
    /// drag (→ snap back). Kept above `Tiler.applyTolerance` so the notification from our
    /// own frame write landing never looks like a drag.
    private static let snapBackTolerance: CGFloat = 3

    /// Adopt / rebind / skip every untracked tileable window of one app.
    ///
    /// Native macOS tabs (e.g. Ghostty) surface as separate AX windows *stacked on the same
    /// frame*, of which only the front one is the app's focused window. So a new window stacked on
    /// an existing same-app tile is a tab: if it's the app's front tab it takes over that leaf in
    /// place (no reshuffle), otherwise it's a background tab and is skipped. A window not stacked
    /// on any tile is a genuine standalone window → adopt. Detection is pure AX (frame + focused
    /// window) — no private window-server calls — so it's robust to apps the CGS path can't id.
    private func reconcileApp(pid: pid_t, dirty: inout Set<SpaceID>) {
        guard let app = apps[pid] else { return }
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
            guard let w = registry.window(for: id), w.pid == pid, let f = w.frame else { continue }
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
            for c in cluster where c.id != keep.id {
                Log.logger.debug("tab dedup: drop stacked leaf \(c.id) (kept \(keep.id)) @ \(frameStr(c.frame))")
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
        return tabDecision(frameMatch: leaf, isFront: isFront, leafAlreadyUsed: claimed)
    }

    /// The managed same-app leaf the given window is stacked on (a native tab joins its group at
    /// the group's frame), or nil if it sits on no existing tile — i.e. it's a standalone window.
    private func frameMatchLeaf(pid: pid_t, frame: CGRect?) -> WinID? {
        var leaves: [(id: WinID, frame: CGRect?)] = []
        for (_, id) in visibleTiledWindows() {
            guard let w = registry.window(for: id), w.pid == pid, !w.isMinimized else { continue }
            leaves.append((id, w.frame ?? desiredFrames[id]))
        }
        return nearestStackedLeaf(frame, among: leaves, tolerance: Self.tabStackTolerance)
    }

    /// On a front-tab close, macOS promotes the next tab to the app's focused window. If that
    /// promoted window is untracked and stacked on the vacated tile, return it so the leaf can
    /// rebind to it instead of collapsing. A normal single-window close has no such sibling → nil.
    private func promotedTabSibling(forClosing id: WinID, pid: pid_t) -> AXUIElement? {
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

    /// Remove managed windows whose AX element is gone — the backstop for a missed/misdirected
    /// `kAXUIElementDestroyed` (notably Firefox). Returns the Spaces that need a retile. Never
    /// reaps a merely hidden / off-Space / occluded window (their elements still answer AX).
    private func reapDeadWindows() -> Set<SpaceID> {
        var dirty: Set<SpaceID> = []
        for tree in Array(trees.values) {                 // snapshot: we mutate tree contents
            for id in tree.windowIDs where !registry.isFloating(id) {
                guard let w = registry.window(for: id), isDead(w) else { continue }
                Log.logger.debug("reap dead window \(id)")
                forget(id, tree: tree)
                dirty.insert(tree.space)
            }
        }
        for tree in parkedTrees {                          // parked trees leak too if dead-but-registered
            for id in tree.windowIDs where !registry.isFloating(id) {
                if let w = registry.window(for: id), isDead(w) { forget(id, tree: tree) }
            }
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

    // MARK: - Trees / displays / Spaces

    @discardableResult
    private func ensureTree(space: SpaceID, display: DisplayID) -> BSPTree {
        if let tree = trees[space] { return tree }
        let tree = BSPTree(display: display, space: space)
        trees[space] = tree
        return tree
    }

    /// Active trees only — what window *commands* (focus/move/resize) operate on. A parked
    /// tree's windows are dormant and must not be command targets.
    private func treeContaining(_ id: WinID) -> BSPTree? { trees.values.first { $0.contains(id) } }

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
    private func forget(_ id: WinID, tree: BSPTree? = nil, newFocus: WinID? = nil) -> BSPTree? {
        let tree = tree ?? anyTreeContaining(id)
        tree?.remove(id)
        registry.unregister(id)
        desiredFrames.removeValue(forKey: id)
        stickyOnce.remove(id)
        if zoomedID == id { zoomedID = nil }
        if focusedID == id { focusedID = newFocus ?? tree?.focused }
        pruneEmptyParkedTrees()
        return tree
    }

    private func pruneEmptyParkedTrees() { parkedTrees.removeAll { $0.isEmpty } }

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
    /// Skip displays whose current Space isn't a user desktop: while the screen is locked
    /// the loginwindow Space is reported as current, and recording it would make `isActive`
    /// false for every real tree (tiling silently stops). Keeping the last-known-good user
    /// Space through the locked interval lets `resync()` restore tiling cleanly on unlock.
    private func refreshActiveSpaces() {
        if spaces.isAvailable {
            for ds in spaces.displayLayout() where ds.currentIsUserSpace {
                if let d = ds.displayID { activeSpace[d] = ds.currentSpace }
            }
        }
        for d in screens.displayIDs where activeSpace[d] == nil { activeSpace[d] = pseudoSpace(d) }
    }

    /// Every non-floating window on a visible desktop, paired with its tree — what tab
    /// reconciliation and focus/move targeting iterate.
    private func visibleTiledWindows() -> [(tree: BSPTree, id: WinID)] {
        var out: [(tree: BSPTree, id: WinID)] = []
        for tree in trees.values where isActive(tree) {
            for id in tree.windowIDs where !registry.isFloating(id) { out.append((tree, id)) }
        }
        return out
    }

    /// Desired frames restricted to windows on the visible desktops — the only windows
    /// that should be focus/move targets.
    private func visibleFrames() -> [WinID: CGRect] {
        var out: [WinID: CGRect] = [:]
        for (_, id) in visibleTiledWindows() { if let f = desiredFrames[id] { out[id] = f } }
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

    /// Retile the given Spaces plus every visible one — the visible pass applies frames
    /// that were only computed while their desktop was hidden (e.g. a window that
    /// arrived off-screen).
    private func retileDirtyAndVisible(_ dirty: Set<SpaceID>) {
        var toRetile = dirty
        for tree in trees.values where isActive(tree) { toRetile.insert(tree.space) }
        toRetile.forEach { if let t = trees[$0] { retile(t) } }
    }

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
        var dirty: Set<SpaceID> = []
        reconcileApp(pid: pid, dirty: &dirty)   // adopt OR rebind OR ignore
        if let id = registry.id(for: element) {                         // nil ⇒ ignored background tab
            focusedID = id
            treeContaining(id)?.focused = id
        }
        dirty.forEach { if let t = trees[$0] { retile(t) } }
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
    }

    /// A tiled window was minimized: remove it from its tree and reflow the rest so no empty
    /// slot is left (like a close, but the window stays registered and parked in
    /// `registry.minimized` for `windowDeminimized` to restore). Gated by `reflow_on_minimize`.
    func windowMinimized(_ element: AXUIElement, pid: pid_t) {
        guard config.layout.reflowOnMinimize else { return }
        guard let id = registry.id(for: element), !registry.isFloating(id) else { return }
        guard let tree = anyTreeContaining(id) else { return }   // already out of a tree → nothing to do
        tree.remove(id)
        registry.setMinimized(id, true)
        desiredFrames.removeValue(forKey: id)          // stop applying a stale frame
        if zoomedID == id { zoomedID = nil }
        if focusedID == id { focusedID = tree.focused }
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
        dirty.forEach { if let t = trees[$0] { retile(t) } }
    }

    func windowMovedOrResized(_ element: AXUIElement, pid: pid_t) {
        guard let id = registry.id(for: element), !registry.isFloating(id), zoomedID != id else { return }
        guard let tree = treeContaining(id),
              let desired = desiredFrames[id],
              let current = registry.window(for: id)?.frame else { return }
        // If a tiled window drifted from its computed slot, the user dragged it: snap back.
        if !rectsApproxEqual(current, desired, Self.snapBackTolerance) { retile(tree) }
    }

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
            Log.logger.debug("park tree space \(space) (display \(tree.display) gone)")
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
            for id in tree.windowIDs {
                existing.insert(id, focusedFrame: nil, ratio: config.layout.defaultRatio)
            }
        } else {
            trees[tree.space] = tree
        }
        Log.logger.debug("restore tree space \(tree.space) onto display \(display)")
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
            targetTree.insert(fid, focusedFrame: desiredFrames[target], ratio: config.layout.defaultRatio)
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
            tree.insert(fid, focusedFrame: tree.focused.flatMap { desiredFrames[$0] },
                        ratio: config.layout.defaultRatio)
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
            if let (tiled, _) = preferredActiveFocus() { focus(windowID: tiled) }
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
        do {
            config = try ConfigLoader.load()
        } catch {
            // Keep the working config — a typo mid-edit must not wipe the live keybindings.
            Log.logger.error("config reload failed: \(error) — keeping the current config")
            onConfigError?("\(error)")
            return
        }
        keymap = Keymap(config: config)
        currentMode = Keymap.defaultMode
        applyKeymap()
        retileAll()
        onConfigError?(nil)
        Log.logger.info("config reloaded")
    }

    func restart() { Relaunch.now() }

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
    ///
    /// `moveFocus` is true only for a genuine user-facing Space switch (the
    /// `activeSpaceDidChange` notification) — then focus is asserted onto the now-visible
    /// desktop. Every other caller (the backstop poll, app activation, display reconfig,
    /// resync) leaves it false so reconciliation only *repairs the focus cache* and never
    /// steals OS keyboard focus out from under the user.
    func reconcileSpaces(moveFocus: Bool = false) {
        refreshActiveSpaces()                          // (1) keep activeSpace fresh
        var dirty: Set<SpaceID> = []

        // (2) Tab-aware discover/adopt/rebind/skip for every app (replaces discoverWindows()):
        // picks up windows whose Space was hidden at startup, and keeps native tab groups to a
        // single tile that follows the front tab.
        for pid in Array(apps.keys) { reconcileApp(pid: pid, dirty: &dirty) }

        // (3) Reap windows whose AX element is gone — the backstop for a missed/misdirected
        // destroy notification (Firefox). After the rebind pass above so a promoted sibling
        // rescues a dead front tab instead of being reaped + re-adopted. Needs only AX (not
        // Spaces), so it runs in pseudo-Space mode too.
        dirty.formUnion(reapDeadWindows())

        guard spaces.isAvailable else {                // pseudo-Space mode: just apply adoptions
            retileDirtyAndVisible(dirty)
            return
        }

        let spaceDisplay = spaceDisplayMap()           // space → owning display, current layout

        // Keep each tree on the display that currently owns its Space. Display ids and
        // space→display assignments both drift across a monitor reconnect, and a stale
        // `tree.display` silently breaks everything keyed off it: `isActive` (activeSpace is
        // keyed by display), `retile` (the screen is keyed by display), and new-window
        // placement. Re-pointing here makes the backstop poll self-heal what used to require
        // a briarWM restart.
        for tree in trees.values {
            guard let d = spaceDisplay[tree.space], d != tree.display else { continue }
            Log.logger.debug("re-point tree space \(tree.space): display \(tree.display) → \(d)")
            tree.display = d
            dirty.insert(tree.space)
        }

        for tree in Array(trees.values) {                 // snapshot: we mutate `trees`
            for id in tree.windowIDs where !registry.isFloating(id) {
                guard let element = registry.window(for: id)?.element,
                      let wid = spaces.cgWindowID(for: element) else { continue }
                let ids = spaces.spaceIDs(for: wid)
                if ids.count > 1 {                        // sticky twice in a row → float it
                    guard stickyOnce.contains(id) else { stickyOnce.insert(id); continue }
                    stickyOnce.remove(id)
                    tree.remove(id)
                    registry.setFloating(id, true)
                    if focusedID == id { focusedID = tree.focused }
                    dirty.insert(tree.space)
                    continue
                }
                stickyOnce.remove(id)
                guard let real = ids.first, real != tree.space else { continue }
                // If this fires every tick for windows you never moved, the window-server's
                // window→Space numbering disagrees with the managed-space dict key — see
                // SpacesManager.spaceID(from:) and switch the preferred key.
                Log.logger.debug("reconcile: \(id) moved space \(tree.space) → \(real)")
                tree.remove(id)
                let dst = ensureTree(space: real, display: spaceDisplay[real] ?? tree.display)
                dst.insert(id, focusedFrame: dst.focused.flatMap { desiredFrames[$0] },
                           ratio: config.layout.defaultRatio)
                if focusedID == id { focusedID = tree.focused }
                dirty.insert(tree.space)
                dirty.insert(real)
            }
        }

        retileDirtyAndVisible(dirty)
        repairFocusCache(moveFocus: moveFocus)
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
        dst.insert(fid, focusedFrame: dst.focused.flatMap { desiredFrames[$0] },
                   ratio: config.layout.defaultRatio)
        retile(srcTree)                                   // active source → gap closes
        retile(dst, force: true)                          // size it even though off-screen
        if config.layout.moveFollowsFocus { switchToDesktop(index) }
    }

    /// Keep `focusedID` pointing at a window on a visible desktop. When the cache is already
    /// valid this is a no-op; otherwise it adopts the deterministic `preferredActiveFocus()`.
    /// Cache-only unless `moveFocus` (a genuine user Space switch) — so the backstop poll,
    /// app activation and display reconfig repair the cache without yanking OS focus. This
    /// also rescues a `focusedID` left pointing at a *parked* window (the old reassert no-op'd
    /// there because `treeContaining` skips parked trees).
    private func repairFocusCache(moveFocus: Bool) {
        if let fid = focusedID, let tree = treeContaining(fid), isActive(tree) { return }
        guard let (id, tree) = preferredActiveFocus() else { return }
        Log.logger.debug("focus repair: \(String(describing: focusedID)) → \(id) on display \(tree.display) space \(tree.space) [moveFocus=\(moveFocus)]")
        if moveFocus { focus(windowID: id) } else { setFocused(id) }
    }

    /// Update the focus cache without touching OS keyboard focus.
    private func setFocused(_ id: WinID) {
        focusedID = id
        treeContaining(id)?.focused = id
    }

    /// The window a focus recovery should land on, chosen deterministically: the frontmost
    /// app's AX-focused window if it's tiled on an active tree (what the user is really
    /// looking at), else the active focus-remembering tree with the lowest `(display, space)`.
    /// Deterministic ordering matters because `trees` is a Dictionary — `first(where:)` would
    /// otherwise pick an arbitrary display.
    private func preferredActiveFocus() -> (WinID, BSPTree)? {
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
    private func activeTarget() -> (WinID, BSPTree)? {
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

    // MARK: - Focus helper

    private func focus(windowID id: WinID) {
        guard let window = registry.window(for: id) else { return }
        focusedID = id
        treeContaining(id)?.focused = id
        // Bring the target's process frontmost and make its window key. On macOS 14+ this
        // SkyLight path is the only reliable cross-app focus transfer; activate() is only a
        // fallback for when the private symbols are unavailable (and is itself unreliable).
        if !spaces.raiseAndFocus(window.element, pid: window.pid) {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
        }
        window.focus()   // AX: mark the window main/focused and raise within its app
    }
}
