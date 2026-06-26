import AppKit

/// Optional menu-bar presence: shows the active mode and offers reload / quit.
final class StatusItemController {
    private let item: NSStatusItem
    private unowned let manager: WindowManager

    init(manager: WindowManager) {
        self.manager = manager
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🌿"

        let menu = NSMenu()
        let header = NSMenuItem(title: "briarWM", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let reload = NSMenuItem(title: "Reload Config", action: #selector(reload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let quit = NSMenuItem(title: "Quit briarWM", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu

        manager.onModeChanged = { [weak self] mode in
            self?.item.button?.title = mode.map { "🌿 \($0)" } ?? "🌿"
        }
    }

    @objc private func reload() { manager.reload() }
    @objc private func quit() { NSApp.terminate(nil) }
}
