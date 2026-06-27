import ApplicationServices
import CoreGraphics

/// Receives high-level AX events. The WindowManager implements this.
protocol AXEventSink: AnyObject {
    func windowCreated(_ element: AXUIElement, pid: pid_t)
    func windowDestroyed(_ element: AXUIElement, pid: pid_t)
    func focusChanged(pid: pid_t)
    func windowMovedOrResized(_ element: AXUIElement, pid: pid_t)
    func appActivated(pid: pid_t)
}

/// Wraps one running application's AX element and its AXObserver. Translates raw
/// AX notifications into `AXEventSink` calls on the main run loop.
final class AXApplication {
    let pid: pid_t
    let element: AXUIElement
    private weak var sink: AXEventSink?
    private var observer: AXObserver?

    init(pid: pid_t, sink: AXEventSink) {
        self.pid = pid
        self.element = AXUIElementCreateApplication(pid)
        self.sink = sink
    }

    func windows() -> [AXUIElement] {
        AXClient.elements(element, kAXWindowsAttribute as String)
    }

    func focusedWindow() -> AXUIElement? {
        AXClient.element(element, kAXFocusedWindowAttribute as String)
    }

    func start() {
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            Unmanaged<AXApplication>.fromOpaque(refcon).takeUnretainedValue()
                .handle(notification as String, element)
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else {
            Log.logger.warning("AXObserverCreate failed for pid \(pid)")
            return
        }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in Self.appNotifications {
            AXObserverAddNotification(obs, element, note as CFString, refcon)
        }
        for window in windows() {
            addWindowNotifications(window, refcon: refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    func stop() {
        guard let obs = observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = nil
    }

    /// Attach the per-window notifications (destroyed / moved / resized) to a window adopted
    /// after `start()` — e.g. one discovered when its Space became active. Safe to call once
    /// per window; AX ignores duplicate registrations.
    func observe(window element: AXUIElement) {
        guard observer != nil else { return }
        addWindowNotifications(element, refcon: Unmanaged.passUnretained(self).toOpaque())
    }

    private func addWindowNotifications(_ window: AXUIElement, refcon: UnsafeMutableRawPointer) {
        guard let obs = observer else { return }
        for note in Self.windowNotifications {
            AXObserverAddNotification(obs, window, note as CFString, refcon)
        }
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            addWindowNotifications(element, refcon: refcon)
            sink?.windowCreated(element, pid: pid)
        case kAXUIElementDestroyedNotification:
            sink?.windowDestroyed(element, pid: pid)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            sink?.focusChanged(pid: pid)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            sink?.windowMovedOrResized(element, pid: pid)
        case kAXApplicationActivatedNotification:
            sink?.appActivated(pid: pid)
        default:
            break
        }
    }

    private static let appNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXApplicationActivatedNotification,
    ]
    private static let windowNotifications: [String] = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]
}
