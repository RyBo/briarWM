import AppKit

/// Bridges NSWorkspace / NSApplication notifications into the WindowManager:
/// app launch/terminate, Space switches, and display reconfiguration.
final class AppWatcher {
    private unowned let manager: WindowManager
    private var tokens: [NSObjectProtocol] = []

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

        tokens.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            self?.manager.retileAll()
        })

        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.manager.screensChanged()
        })
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
