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
        // This is a genuine user-facing Space switch, so assert focus onto the now-visible
        // desktop (moveFocus: true) — unlike the poll/app-activation reconciles below.
        tokens.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            self?.manager.reconcileSpaces(moveFocus: true)
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

        // Display/system sleep: between lid close and actual sleep the poll can still fire,
        // and every liveness signal (AX exists, CGS window id, Space membership) reads "gone"
        // for windows that are fine — suspend the reconcile gate until a wake path settles it.
        let sleep: (Notification) -> Void = { [weak self] _ in self?.manager.displaysWillSleep() }
        tokens.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                     object: nil, queue: .main, using: sleep))
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification,
                                     object: nil, queue: .main, using: sleep))

        // Returning from sleep or screen unlock fires neither a reliable Space-change nor
        // an app-activation notification, and while locked the active Space is the
        // loginwindow Space — so force a full re-sync to restore tiling on wake/unlock.
        // `screenIsUnlocked` is a private-but-stable DistributedNotificationCenter name.
        let resync: (Notification) -> Void = { [weak self] _ in self?.manager.resync() }
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                     object: nil, queue: .main, using: resync))
        tokens.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                     object: nil, queue: .main, using: resync))
        tokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main, using: resync))

        // Backstop: a Mission Control *drag-to-thumbnail* that doesn't switch the active
        // Space fires neither an AX nor a Space-change notification, so the source gap
        // would otherwise linger. Poll to catch it (`space_poll_interval: 0` disables;
        // takes effect on restart). Idle ticks early-out on a window-server fingerprint.
        let interval = manager.config.layout.spacePollInterval
        if interval > 0 {
            pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.manager.pollReconcile()
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        // Tokens span three centers (workspace, default, distributed); removing a token
        // from a center that doesn't hold it is a harmless no-op, so clear all three.
        let ws = NSWorkspace.shared.notificationCenter
        tokens.forEach {
            ws.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
    }
}
