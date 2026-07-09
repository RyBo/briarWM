import AppKit

/// Wires everything together: accessory app, Accessibility permission gate, config
/// load + watch, window manager, and the status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: WindowManager?
    private var watcher: AppWatcher?
    private var statusItem: StatusItemController?
    private var configWatcher: ConfigWatcher?
    private var permissionTimer: Timer?
    private var overlay: FocusOverlayController?
    /// SIGINT/SIGTERM sources kept alive for the process's lifetime so a `make run` Ctrl-C or a
    /// `kill` flushes the layout before exit. (`applicationWillTerminate` covers the AppKit path.)
    private var signalSources: [DispatchSourceSignal] = []

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
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            guard PermissionGate.isTrusted(prompt: false) else { return }
            timer.invalidate()
            Log.logger.info("Accessibility granted — relaunching")
            Relaunch.now()
        }
    }

    private func startManager() {
        // At startup there is no last-good config to keep, so fall back to defaults —
        // but surface the parse error in the status item instead of failing silently.
        var configError: String?
        let config: Config
        do {
            config = try ConfigLoader.load()
        } catch {
            Log.logger.error("config parse error: \(error) — starting with defaults")
            configError = "\(error)"
            config = Config()
        }
        let manager = WindowManager(config: config)
        self.manager = manager

        let watcher = AppWatcher(manager: manager)
        watcher.start()
        self.watcher = watcher

        let overlay = FocusOverlayController(style: config.focusIndicator)
        manager.onFocusOverlayUpdate = { [weak overlay] frame, pulse in overlay?.update(frame: frame, pulse: pulse) }
        manager.onConfigReloaded = { [weak overlay] cfg in overlay?.applyStyle(cfg.focusIndicator) }
        self.overlay = overlay

        manager.start()
        installTerminationHandlers()
        statusItem = StatusItemController(manager: manager)
        if let configError { statusItem?.showConfigError(configError) }

        configWatcher = ConfigWatcher(url: ConfigLoader.configURL) { [weak manager] in
            manager?.reload()
        }
        configWatcher?.start()
    }

    /// Flush the layout on the AppKit terminate path (`restart` command, Quit, logout). Cheap
    /// and idempotent, so double-flushing alongside the signal handlers is fine.
    func applicationWillTerminate(_ notification: Notification) {
        manager?.saveLayoutNow()
    }

    /// AppKit doesn't route bare SIGINT/SIGTERM through `applicationWillTerminate`, so a `make
    /// run` Ctrl-C or a `kill` would lose the layout. Ignore the default disposition and handle
    /// each on the main queue: flush, then terminate cleanly.
    private func installTerminationHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.manager?.saveLayoutNow()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
