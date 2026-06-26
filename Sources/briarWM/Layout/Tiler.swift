import CoreGraphics

func rectsApproxEqual(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
    abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// Applies computed frames to live windows via AX, skipping windows already at
/// their target (avoids needless writes and the AX notifications they trigger).
enum Tiler {
    static func apply(_ frames: [WinID: CGRect], registry: WindowRegistry) {
        for (id, target) in frames {
            guard let window = registry.window(for: id) else { continue }
            if let current = window.frame, rectsApproxEqual(current, target) { continue }
            window.setFrame(target)
        }
    }
}
