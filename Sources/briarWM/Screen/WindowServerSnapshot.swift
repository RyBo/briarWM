import CoreGraphics
import Foundation

/// A cheap structural fingerprint of the window server's on-screen state — one public
/// `CGWindowListCopyWindowInfo` call, no per-window AX traffic. If two snapshots are
/// equal, no normal-layer window appeared, closed, minimized, moved, resized, or
/// switched desktops since the last capture, so the backstop poll can skip its full
/// per-app reconcile sweep. Bounds are included so a cross-display drag (same window,
/// same on-screen set, new place) still registers as a change.
struct WindowServerSnapshot: Equatable {
    let windows: [CGWindowID: CGRect]

    /// nil when the window list is unavailable — callers must treat that as "changed"
    /// and reconcile anyway (never skip on doubt).
    static func capture() -> WindowServerSnapshot? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        var windows: [CGWindowID: CGRect] = [:]
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = w[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            windows[CGWindowID(num)] = bounds
        }
        return WindowServerSnapshot(windows: windows)
    }

    /// Just the on-screen normal-layer window ids — nil when the list is unavailable, so
    /// callers fail closed (treat "unknown" as "can't disambiguate", never as on-screen).
    static func onscreenIDs() -> Set<CGWindowID>? { capture().map { Set($0.windows.keys) } }
}
