/// Dispatches a parsed `Action` to the corresponding `WindowManager` operation.
/// Keeps hotkeys (and, later, a status menu / IPC) funneling through one place.
final class CommandRouter {
    private unowned let manager: WindowManager

    init(manager: WindowManager) { self.manager = manager }

    func perform(_ action: Action) {
        switch action {
        case .focus(let d):       manager.focusDirection(d)
        case .move(let d):        manager.moveDirection(d)
        case .resize(let d, let px): manager.resizeFocused(d, px)
        case .preselect(let o):   manager.preselect(o)
        case .toggleSplit:        manager.toggleSplit()
        case .balance:            manager.balanceFocusedDisplay()
        case .fullscreen:         manager.toggleFullscreen()
        case .toggleFloat:        manager.toggleFloatFocused()
        case .focusModeToggle:    manager.focusModeToggle()
        case .close:              manager.closeFocused()
        case .exec(let s):        manager.runExec(s)
        case .reload:             manager.reload()
        case .restart:            manager.restart()
        case .enterMode(let n):   manager.enterMode(n)
        case .exitMode:           manager.exitMode()
        case .dumpTree:           manager.dumpTree()
        }
    }
}
