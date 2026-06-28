import ApplicationServices
import CoreGraphics

/// Value wrapper around a single window's AXUIElement. Identity is by the
/// underlying element (CFEqual), not by frame.
struct AXWindow: Equatable {
    let element: AXUIElement
    let pid: pid_t

    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    var title: String? { AXClient.string(element, kAXTitleAttribute as String) }
    var role: String? { AXClient.string(element, kAXRoleAttribute as String) }
    var subrole: String? { AXClient.string(element, kAXSubroleAttribute as String) }

    var position: CGPoint? { AXClient.point(element, kAXPositionAttribute as String) }
    var size: CGSize? { AXClient.size(element, kAXSizeAttribute as String) }
    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    var isMinimized: Bool { AXClient.bool(element, kAXMinimizedAttribute as String) ?? false }
    var isFullscreen: Bool { AXClient.bool(element, "AXFullScreen") ?? false }
    var isResizable: Bool { AXClient.isSettable(element, kAXSizeAttribute as String) }

    /// False once the underlying window is gone. Reads `kAXRole` and treats a destroyed
    /// element (`.invalidUIElement`) or a dead/unresponsive app (`.cannotComplete`) as dead.
    /// A merely hidden / off-Space / occluded window answers `.success` → still alive.
    var exists: Bool {
        switch AXClient.attributeError(element, kAXRoleAttribute as String) {
        case .invalidUIElement, .cannotComplete: return false
        default: return true
        }
    }

    @discardableResult
    func setPosition(_ p: CGPoint) -> Bool { AXClient.setPoint(element, kAXPositionAttribute as String, p) }
    @discardableResult
    func setSize(_ s: CGSize) -> Bool { AXClient.setSize(element, kAXSizeAttribute as String, s) }

    /// Apply size → position → size (apps clamp position against the current size and
    /// vice versa, so a single pass can land in the wrong spot).
    @discardableResult
    func setFrame(_ rect: CGRect) -> Bool {
        _ = setSize(rect.size)
        let okPos = setPosition(rect.origin)
        let okSize = setSize(rect.size)
        return okPos && okSize
    }

    func raise() {
        AXClient.performAction(element, kAXRaiseAction as String)
    }

    /// Make this the app's focused/main window and raise it.
    func focus() {
        AXClient.setAttribute(element, kAXMainAttribute as String, kCFBooleanTrue)
        AXClient.setAttribute(element, kAXFocusedAttribute as String, kCFBooleanTrue)
        raise()
    }

    /// Press the window's close button.
    func close() {
        if let button = AXClient.element(element, kAXCloseButtonAttribute as String) {
            AXClient.performAction(button, kAXPressAction as String)
        }
    }
}
