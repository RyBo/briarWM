import AppKit

struct ScreenInfo: Equatable {
    let displayID: DisplayID
    let frame: CGRect          // Cocoa coordinates
    let visibleFrame: CGRect   // Cocoa, excludes menu bar + Dock
}

/// Enumerates displays and converts their geometry into the AX coordinate space
/// the layout engine works in.
final class ScreenManager {
    private(set) var screens: [ScreenInfo] = []
    /// Height of the screen whose Cocoa origin is (0,0) — the Y-flip constant.
    private(set) var primaryHeight: CGFloat = 0

    init() { refresh() }

    func refresh() {
        let nsScreens = NSScreen.screens
        primaryHeight = nsScreens.first?.frame.height ?? 0
        screens = nsScreens.map { s in
            let number = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return ScreenInfo(displayID: number, frame: s.frame, visibleFrame: s.visibleFrame)
        }
    }

    var displayIDs: [DisplayID] { screens.map(\.displayID) }
    func screen(for id: DisplayID) -> ScreenInfo? { screens.first { $0.displayID == id } }

    /// True when at least one enumerated display is powered on. While every display sleeps
    /// (lid closed, no external), AX liveness and CGS Space queries read garbage for windows
    /// that are perfectly fine — reconciliation must not trust them until this is true again.
    var anyDisplayAwake: Bool {
        screens.contains { CGDisplayIsAsleep($0.displayID) == 0 }
    }

    /// Tiling rectangle for a screen in AX coordinates, inset by the outer gap.
    func tilingAreaAX(for screen: ScreenInfo, outerGap: CGFloat) -> CGRect {
        Geometry.cocoaToAX(screen.visibleFrame, primaryHeight: primaryHeight)
            .insetBy(dx: outerGap, dy: outerGap)
    }

    /// The display whose AX frame contains the center of `axRect` (falls back to primary).
    func displayForAXRect(_ axRect: CGRect) -> DisplayID? {
        let center = CGPoint(x: axRect.midX, y: axRect.midY)
        for s in screens {
            if Geometry.cocoaToAX(s.frame, primaryHeight: primaryHeight).contains(center) {
                return s.displayID
            }
        }
        return screens.first?.displayID
    }
}
