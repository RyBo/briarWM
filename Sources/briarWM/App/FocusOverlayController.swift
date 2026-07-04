import AppKit

/// The focus cue: a single reusable, click-through overlay `NSPanel` that draws a soft
/// glowing **border** around the focused window and gives it one quick bounce on each focus
/// switch. Dimmed below full opacity and feathered by `glow`, so it reads as a gentle pulse
/// of light rather than a hard rectangle. Purely decorative — it never calls AX, never
/// touches window frames, and never steals focus, so it can't perturb tiling or the
/// snap-back machinery.
///
/// AppKit-only, App layer. Driven by `WindowManager.onFocusOverlayUpdate` (position + pulse)
/// and `onConfigReloaded` (style). Geometry-agnostic: it just draws at a global-Cocoa rect,
/// the same space as `NSWindow.setFrame`; `WindowManager` owns the AX→Cocoa conversion.
final class FocusOverlayController {
    private let panel: NSPanel
    private let borderLayer = CAShapeLayer()
    private var style: FocusIndicator
    /// The last window rect (global Cocoa) we were shown at — replayed by `applyStyle` when
    /// metrics change so the border re-lays-out without waiting for the next focus event.
    private var currentFrame: CGRect?

    /// The border-pulse animation's key on the border layer; removing it re-pins opacity to 0.
    private static let pulseKey = "focus-pulse"

    init(style: FocusIndicator) {
        self.style = style
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true         // clicks pass through to the window below
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let content = NSView(frame: .zero)
        content.wantsLayer = true
        content.layer?.addSublayer(borderLayer)
        panel.contentView = content

        borderLayer.fillColor = nil
        borderLayer.opacity = 0                  // hidden except during a pulse
        borderLayer.shadowOffset = .zero         // the glow is a same-color, un-offset blur

        applyStyle(style)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Public API

    /// Reposition the overlay onto `frame` (a global-Cocoa window rect), or hide it when
    /// `frame` is nil. `pulse` also fires the border bounce — set only on a real focus change,
    /// not on a retile/resize follow, so the border can track a window without re-flashing.
    func update(frame: CGRect?, pulse: Bool) {
        guard let frame else { hide(); return }
        currentFrame = frame
        layout(for: frame)
        panel.orderFrontRegardless()             // never steals focus (non-activating)
        if pulse { firePulse() }
    }

    /// Adopt a reloaded config: rebuild colors/metrics and re-lay-out at the current frame.
    func applyStyle(_ style: FocusIndicator) {
        self.style = style
        let accent = Self.nsColor(style.color).cgColor
        borderLayer.strokeColor = accent
        borderLayer.lineWidth = style.borderWidth
        borderLayer.shadowColor = accent        // same-color glow feathers the stroke
        borderLayer.shadowRadius = style.glow
        borderLayer.shadowOpacity = style.glow > 0 ? 1 : 0
        if let currentFrame { layout(for: currentFrame) } else { hide() }
    }

    // MARK: - Drawing

    private func hide() {
        currentFrame = nil
        panel.orderOut(nil)
    }

    /// Position the panel (outset enough for the stroke + glow to bleed outward) and rebuild
    /// the border path. Position/relayout must be instantaneous — only the border *opacity*
    /// animates — so it runs inside a `CATransaction` with implicit actions disabled.
    private func layout(for windowFrame: CGRect) {
        let padding = style.borderWidth + style.glow
        let panelFrame = windowFrame.insetBy(dx: -padding, dy: -padding)
        panel.setFrame(panelFrame, display: true)

        guard let content = panel.contentView else { return }
        let scale = panel.backingScaleFactor
        let bounds = CGRect(origin: .zero, size: panelFrame.size)
        // The window rect in the content view's own (bottom-left origin) coordinate space.
        let inset = CGRect(x: padding, y: padding, width: windowFrame.width, height: windowFrame.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer?.frame = bounds

        borderLayer.frame = bounds
        borderLayer.contentsScale = scale
        borderLayer.rasterizationScale = scale
        // Inset by half the line width so the stroke lands centered on the window edge.
        let strokeRect = inset.insetBy(dx: style.borderWidth / 2, dy: style.borderWidth / 2)
        let radius = max(0, style.cornerRadius - style.borderWidth / 2)
        let path = CGPath(roundedRect: strokeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        borderLayer.path = path
        // Leave shadowPath nil: the glow is then derived from the layer's *rendered* content —
        // the thin stroked line — so it feathers around the border. A shadowPath here would be
        // treated as a filled silhouette and flood the whole window interior with glow.
        borderLayer.shadowPath = nil
        CATransaction.commit()
    }

    /// A smooth swell-and-fade: opacity 0 → `peak` → 0, with an optional `hold` plateau at
    /// the peak (default 0). Both the rise and the fall use ease-in-ease-out — the standard
    /// macOS curve — which decelerates to zero velocity at the peak, so the apex is a soft
    /// turnaround rather than a sharp snap. `peak` sits below 1 so the cue stays gentle. The
    /// model opacity is left at 0, so the border vanishes between switches.
    private func firePulse() {
        borderLayer.removeAnimation(forKey: Self.pulseKey)
        let total = style.fadeIn + style.hold + style.fadeOut
        guard total > 0 else { return }
        let peak = max(0, min(1, style.opacity))

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, peak, peak, 0]
        anim.keyTimes = [0,
                         NSNumber(value: style.fadeIn / total),
                         NSNumber(value: (style.fadeIn + style.hold) / total),
                         1]
        anim.duration = total
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.timingFunctions = [ease, ease, ease]   // middle segment is zero-length when hold == 0
        borderLayer.opacity = 0
        borderLayer.add(anim, forKey: Self.pulseKey)
    }

    @objc private func screenParametersChanged() {
        if let currentFrame { layout(for: currentFrame) }   // pick up a new backingScaleFactor
    }

    /// Convert the pure `HexColor` to an sRGB `NSColor`. AppKit conversion stays in the App
    /// layer so `Config` remains AppKit-free.
    private static func nsColor(_ c: HexColor) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
