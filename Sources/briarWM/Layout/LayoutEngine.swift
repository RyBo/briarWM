import CoreGraphics

/// Pure tree → rectangles. No side effects, no AX — the most heavily unit-tested
/// part of briarWM. All rectangles are in AX (top-left origin) coordinates.
enum LayoutEngine {

    /// Compute one frame per window for `root` filling `area`, inserting `innerGap`
    /// between siblings. `area` should already be inset by the outer gap.
    static func computeFrames(root: BSPNode?, area: CGRect, innerGap: CGFloat) -> [WinID: CGRect] {
        guard let root else { return [:] }
        var out: [WinID: CGRect] = [:]
        frames(root, area, innerGap, &out)
        return out
    }

    private static func frames(_ node: BSPNode, _ rect: CGRect, _ inner: CGFloat, _ out: inout [WinID: CGRect]) {
        switch node.kind {
        case .leaf(let id):
            out[id] = rect

        case .split(let orientation, let ratio, let a, let b):
            let r = CGFloat(ratio)
            if orientation == .horizontal {
                let usable = max(0, rect.width - inner)
                let wA = (usable * r).rounded()
                let rectA = CGRect(x: rect.minX, y: rect.minY, width: wA, height: rect.height)
                // B absorbs the rounding remainder so the two children fill `rect` exactly.
                let rectB = CGRect(x: rect.minX + wA + inner, y: rect.minY,
                                   width: max(0, rect.width - wA - inner), height: rect.height)
                frames(a, rectA, inner, &out)
                frames(b, rectB, inner, &out)
            } else {
                let usable = max(0, rect.height - inner)
                let hA = (usable * r).rounded()
                let rectA = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: hA)
                let rectB = CGRect(x: rect.minX, y: rect.minY + hA + inner,
                                   width: rect.width, height: max(0, rect.height - hA - inner))
                frames(a, rectA, inner, &out)
                frames(b, rectB, inner, &out)
            }
        }
    }
}
