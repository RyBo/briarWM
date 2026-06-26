import AppKit
import ApplicationServices

/// The orchestrator: owns one BSP tree per display, tracks windows/apps, responds
/// to AX events and hotkey-driven commands, and re-tiles. Everything runs on the
/// main thread, so no locking is needed.
final class WindowManager: AXEventSink {
    private(set) var config: Config
    private let screens = ScreenManager()
    private let registry = WindowRegistry()
    private let hotkeys = HotkeyManager()

    private var apps: [pid_t: AXApplication] = [:]
    private var trees: [DisplayID: BSPTree] = [:]
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
        for s in screens.screens { ensureTree(s.displayID) }
        applyKeymap()
        adoptExistingWindows()
        retileAll()
        let tiled = trees.values.reduce(0) { $0 + $1.windowIDs.count }
        Log.logger.info("briarWM started: \(tiled) tiled, \(registry.floating.count) floating, \(trees.count) display(s)")
    }

    private func adoptExistingWindows() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            addApp(pid: app.processIdentifier)
        }
    }

    // MARK: - App tracking

    func addApp(pid: pid_t) {
        guard pid != getpid(), apps[pid] == nil else { return }
        let axApp = AXApplication(pid: pid, sink: self)
        apps[pid] = axApp
        axApp.start()
        var changed: Set<DisplayID> = []
        for element in axApp.windows() where registry.id(for: element) == nil {
            considerWindow(element, pid: pid, retile: false)
            if let id = registry.id(for: element), let tree = treeContaining(id) { changed.insert(tree.display) }
        }
        changed.forEach { retile($0) }
    }

    func removeApp(pid: pid_t) {
        guard let axApp = apps[pid] else { return }
        axApp.stop()
        apps.removeValue(forKey: pid)
        let ids = trees.values.flatMap { $0.windowIDs }.filter { registry.window(for: $0)?.pid == pid }
        var changed: Set<DisplayID> = []
        for id in ids {
            if let tree = treeContaining(id) { tree.remove(id); changed.insert(tree.display) }
            registry.unregister(id)
            desiredFrames.removeValue(forKey: id)
        }
        changed.forEach { retile($0) }
    }

    // MARK: - Window adoption / filtering

    private func considerWindow(_ element: AXUIElement, pid: pid_t, retile doRetile: Bool) {
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
        let tree = ensureTree(display)
        let focusedFrame = tree.focused.flatMap { desiredFrames[$0] } ?? window.frame
        tree.insert(id, focusedFrame: focusedFrame,
                    insertAt: InsertAt(rawValue: config.layout.insertAt) ?? .after,
                    autoSplit: config.layout.autoSplit)
        focusedID = id
        Log.logger.debug("tile \(id) \(window.title ?? "?") on display \(display)")
        if doRetile { retile(display) }
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

    // MARK: - Trees / displays

    @discardableResult
    private func ensureTree(_ display: DisplayID) -> BSPTree {
        if let tree = trees[display] { return tree }
        let tree = BSPTree(display: display)
        trees[display] = tree
        return tree
    }

    private func treeContaining(_ id: WinID) -> BSPTree? { trees.values.first { $0.contains(id) } }

    private func displayForWindow(_ window: AXWindow) -> DisplayID {
        if let frame = window.frame, let display = screens.displayForAXRect(frame) { return display }
        return screens.displayIDs.first ?? 0
    }

    private func displayForID(_ id: WinID) -> DisplayID? {
        if let frame = registry.window(for: id)?.frame { return screens.displayForAXRect(frame) }
        return treeContaining(id)?.display
    }

    // MARK: - Tiling

    func retileAll() { trees.keys.forEach { retile($0) } }

    private func retile(_ display: DisplayID) {
        guard let tree = trees[display], let screen = screens.screen(for: display) else { return }
        let area = screens.tilingAreaAX(for: screen, outerGap: config.gaps.outer)
        var frames = LayoutEngine.computeFrames(root: tree.root, area: area, innerGap: config.gaps.inner)
        if let z = zoomedID, tree.contains(z) { frames[z] = area }   // fullscreen override
        for (id, rect) in frames { desiredFrames[id] = rect }
        Tiler.apply(frames, registry: registry)
        if let z = zoomedID, tree.contains(z) { registry.window(for: z)?.raise() }
    }

    // MARK: - AXEventSink

    func windowCreated(_ element: AXUIElement, pid: pid_t) {
        considerWindow(element, pid: pid, retile: true)
    }

    func windowDestroyed(_ element: AXUIElement, pid: pid_t) {
        guard let id = registry.id(for: element) else { return }
        let display = treeContaining(id)?.display
        treeContaining(id)?.remove(id)
        registry.unregister(id)
        desiredFrames.removeValue(forKey: id)
        if zoomedID == id { zoomedID = nil }
        if focusedID == id { focusedID = display.flatMap { trees[$0]?.focused } }
        if let display { retile(display) }
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
        if !rectsApproxEqual(current, desired, 3) { retile(tree.display) }
    }

    func appActivated(pid: pid_t) {
        guard let focused = apps[pid]?.focusedWindow(), let id = registry.id(for: focused) else { return }
        focusedID = id
        treeContaining(id)?.focused = id
    }

    func screensChanged() {
        screens.refresh()
        let valid = Set(screens.displayIDs)
        valid.forEach { ensureTree($0) }
        let primary = screens.displayIDs.first ?? 0
        for (display, tree) in trees where !valid.contains(display) {
            for id in tree.windowIDs { ensureTree(primary).insert(id, focusedFrame: nil) }
            trees.removeValue(forKey: display)
        }
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
        guard let fid = focusedID, let tree = treeContaining(fid) else { return }
        let frames = config.layout.focusWrapsMonitors
            ? desiredFrames
            : desiredFrames.filter { treeContaining($0.key)?.display == tree.display }
        if let target = tree.adjacent(to: fid, direction: dir, frames: frames) {
            focus(windowID: target)
        }
    }

    func moveDirection(_ dir: Direction) {
        guard let fid = focusedID, let tree = treeContaining(fid),
              let target = tree.adjacent(to: fid, direction: dir, frames: desiredFrames),
              let targetTree = treeContaining(target) else { return }
        if targetTree.display == tree.display {
            tree.swap(fid, target)
            retile(tree.display)
        } else {
            tree.remove(fid)
            targetTree.insert(fid, focusedFrame: desiredFrames[target])
            targetTree.focused = fid
            focusedID = fid
            retile(tree.display)
            retile(targetTree.display)
        }
    }

    func resizeFocused(_ dir: Direction, _ px: CGFloat) {
        guard let fid = focusedID, let tree = treeContaining(fid) else { return }
        tree.resize(fid, edge: dir, deltaPx: px, frames: desiredFrames)
        retile(tree.display)
    }

    func preselect(_ orientation: Orientation) {
        guard let fid = focusedID, let tree = treeContaining(fid) else { return }
        tree.preselect = orientation
    }

    func toggleSplit() {
        guard let fid = focusedID, let tree = treeContaining(fid) else { return }
        tree.toggleSplitOrientation(of: fid)
        retile(tree.display)
    }

    func balanceFocusedDisplay() {
        guard let fid = focusedID, let tree = treeContaining(fid) else { return }
        tree.balance()
        retile(tree.display)
    }

    func toggleFullscreen() {
        guard let fid = focusedID, let tree = treeContaining(fid) else { return }
        zoomedID = (zoomedID == fid) ? nil : fid
        retile(tree.display)
    }

    func toggleFloatFocused() {
        guard let fid = focusedID else { return }
        if registry.isFloating(fid) {
            registry.setFloating(fid, false)
            let display = displayForID(fid) ?? screens.displayIDs.first ?? 0
            let tree = ensureTree(display)
            tree.insert(fid, focusedFrame: tree.focused.flatMap { desiredFrames[$0] })
            retile(display)
        } else if let tree = treeContaining(fid) {
            tree.remove(fid)
            registry.setFloating(fid, true)
            retile(tree.display)
        }
    }

    func focusModeToggle() {
        // i3's mod+space (cycle focus between tiled/floating) — minimal: focus a floating
        // window if a tiled one is focused, else focus the focused tree's window.
        guard let fid = focusedID else { return }
        if registry.isFloating(fid) {
            if let tiled = trees.values.first(where: { $0.focused != nil })?.focused { focus(windowID: tiled) }
        } else if let anyFloating = registry.floating.first {
            focus(windowID: anyFloating)
        }
    }

    func closeFocused() {
        guard let fid = focusedID else { return }
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
        Log.logger.info("display \(tree.display) focused=\(String(describing: tree.focused))\n\(tree.root?.describe() ?? "<empty>")")
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
