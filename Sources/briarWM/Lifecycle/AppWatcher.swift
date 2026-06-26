import AppKit

/// Bridges NSWorkspace / NSApplication notifications into the WindowManager:
/// app launch/terminate, Space switches, and display reconfiguration.
final class AppWatcher {
    private unowned let manager: WindowManager
    private var tokens: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    init(manager: WindowManager) { self.manager = manager }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter

        tokens.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                     object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.manager.addApp(pid: app.processIdentifier)
            }
        })

        tokens.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                     object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.manager.removeApp(pid: app.processIdentifier)
            }
        })

        // Desktop switch: reconcile each window's tree against its real Space, then
        // retile the now-visible desktops (closes the source gap, sizes the destination).
        tokens.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            self?.manager.reconcileSpaces()
        })

        // App activation often coincides with the user finishing a drag-to-desktop;
        // reconcile opportunistically (cheap — only active trees ever touch AX).
        tokens.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            self?.manager.reconcileSpaces()
        })

        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.manager.screensChanged()
        })

        // Backstop: a Mission Control *drag-to-thumbnail* that doesn't switch the active
        // Space fires neither an AX nor a Space-change notification, so the source gap
        // would otherwise linger. Poll to catch it (`space_poll_interval: 0` disables).
        let interval = manager.config.layout.spacePollInterval
        if interval > 0 {
            pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.manager.reconcileSpaces()
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
