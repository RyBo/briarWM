import AppKit

/// Optional menu-bar presence: shows the active mode and config errors, offers reload / quit.
final class StatusItemController {
    private let item: NSStatusItem
    private unowned let manager: WindowManager
    private let errorItem: NSMenuItem
    private var mode: String?
    private var configError: String?

    init(manager: WindowManager) {
        self.manager = manager
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🌿"

        let menu = NSMenu()
        let header = NSMenuItem(title: "briarWM", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)
        menu.addItem(.separator())

        let reload = NSMenuItem(title: "Reload Config", action: #selector(reload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let quit = NSMenuItem(title: "Quit briarWM", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu

        manager.onModeChanged = { [weak self] mode in
            self?.mode = mode
            self?.refreshTitle()
        }
        manager.onConfigError = { [weak self] message in
            self?.showConfigError(message)
        }
    }

    /// Show a config load failure in the menu bar (first line in the menu, full error in
    /// the tooltip), or clear it (`message == nil`) once a reload succeeds.
    func showConfigError(_ message: String?) {
        configError = message.map { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
        errorItem.isHidden = configError == nil
        errorItem.title = configError.map { "⚠︎ Config error: \($0)" } ?? ""
        item.button?.toolTip = message
        refreshTitle()
    }

    private func refreshTitle() {
        var title = configError == nil ? "🌿" : "🌿⚠︎"
        if let mode { title += " \(mode)" }
        item.button?.title = title
    }

    @objc private func reload() { manager.reload() }
    @objc private func quit() { NSApp.terminate(nil) }
}
