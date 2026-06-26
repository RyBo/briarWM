import AppKit

/// Wires everything together: accessory app, Accessibility permission gate, config
/// load + watch, window manager, and the status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: WindowManager?
    private var watcher: AppWatcher?
    private var statusItem: StatusItemController?
    private var configWatcher: ConfigWatcher?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if PermissionGate.isTrusted(prompt: true) {
            startManager()
        } else {
            Log.logger.warning("Accessibility permission not granted — grant briarWM in System Settings › Privacy & Security › Accessibility. Waiting…")
            waitForPermission()
        }
    }

    /// AX clients created before the grant stay broken, so relaunch once granted.
    private func waitForPermission() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard PermissionGate.isTrusted(prompt: false) else { return }
            timer.invalidate()
            Log.logger.info("Accessibility granted — relaunching")
            self?.relaunch()
        }
    }

    private func startManager() {
        let config = ConfigLoader.load()
        let manager = WindowManager(config: config)
        self.manager = manager

        let watcher = AppWatcher(manager: manager)
        watcher.start()
        self.watcher = watcher

        manager.start()
        statusItem = StatusItemController(manager: manager)

        configWatcher = ConfigWatcher(url: ConfigLoader.configURL) { [weak manager] in
            manager?.reload()
        }
        configWatcher?.start()
    }

    private func relaunch() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        proc.arguments = Array(CommandLine.arguments.dropFirst())
        try? proc.run()
        NSApp.terminate(nil)
    }
}
