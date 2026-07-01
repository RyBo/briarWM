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
}
