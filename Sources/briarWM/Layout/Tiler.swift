import CoreGraphics

func rectsApproxEqual(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = Tiler.applyTolerance) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
    abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// Applies computed frames to live windows via AX, skipping windows already at
/// their target (avoids needless writes and the AX notifications they trigger).
enum Tiler {
    /// A window within this many px of its target counts as already there — skip the
    /// write. Tolerates apps that round their frames; the skip is also what lets our
    /// own frame-landing notifications converge instead of ping-ponging.
    static let applyTolerance: CGFloat = 2

    static func apply(_ frames: [WinID: CGRect], registry: WindowRegistry) {
        for (id, target) in frames {
            guard let window = registry.window(for: id) else { continue }
            guard let current = window.frame else { window.setFrame(target); continue }
            if rectsApproxEqual(current, target) { continue }
            // The full size→position→size dance is only needed when both change (apps clamp
            // position against size and vice versa). A pure move or pure resize is one write.
            let sameSize = abs(current.width - target.width) <= applyTolerance &&
                           abs(current.height - target.height) <= applyTolerance
            let sameOrigin = abs(current.minX - target.minX) <= applyTolerance &&
                             abs(current.minY - target.minY) <= applyTolerance
            if sameSize {
                window.setPosition(target.origin)
            } else if sameOrigin {
                window.setSize(target.size)
            } else {
                window.setFrame(target)
            }
        }
    }
}
