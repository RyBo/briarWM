import CoreGraphics

/// Coordinate conversion between Cocoa (NSScreen) and Accessibility spaces.
///
/// - Cocoa: origin bottom-left of the primary display, y increases upward.
/// - AX:    origin top-left of the primary display, y increases downward.
///
/// `primaryHeight` is the height of the screen whose Cocoa frame origin is (0, 0)
/// — i.e. `NSScreen.screens.first`, NOT `NSScreen.main`.
enum Geometry {

    /// Cocoa rect → AX rect. The transform is its own inverse for rectangles.
    static func cocoaToAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// AX rect → Cocoa rect.
    static func axToCocoa(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// Cocoa point → AX point.
    static func cocoaToAX(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// AX point → Cocoa point.
    static func axToCocoa(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
