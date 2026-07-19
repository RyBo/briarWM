import CoreGraphics

/// Coordinate conversion between Cocoa (NSScreen) and Accessibility spaces.
///
/// - Cocoa: origin bottom-left of the primary display, y increases upward.
/// - AX:    origin top-left of the primary display, y increases downward.
///
/// `primaryHeight` is the height of the screen whose Cocoa frame origin is (0, 0)
/// — i.e. `NSScreen.screens.first`, NOT `NSScreen.main`.
enum Geometry {

    /// Cocoa rect → AX rect. The flip is its own inverse, so this one function covers
    /// both directions (production only ever converts Cocoa → AX, once, at the
    /// NSScreen boundary in `ScreenManager`).
    static func cocoaToAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// Bottom-center origin (Cocoa coords) for a HUD panel of `size` inside `visibleFrame`,
    /// sitting `bottomOffset` points above the frame's bottom edge — the classic macOS
    /// volume-bezel zone. x is rounded so the panel lands on a whole point and its text
    /// stays crisp.
    static func hudOrigin(size: CGSize, visibleFrame: CGRect, bottomOffset: CGFloat) -> CGPoint {
        CGPoint(x: (visibleFrame.midX - size.width / 2).rounded(),
                y: visibleFrame.minY + bottomOffset)
    }
}
