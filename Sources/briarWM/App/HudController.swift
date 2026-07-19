import AppKit

/// The transient mode bezel: one reusable click-through `NSPanel` that flashes a mode
/// change (float, zoom, split, workspace float, binding mode) at the lower center of the
/// focused window's display, then fades out — the classic macOS volume-bezel treatment.
/// Dark translucent rounded rect (`.hudWindow` material) with an SF Symbol + label. Fade
/// only, no slide. Purely decorative: it never calls AX, never touches frames, never steals
/// focus, and sits at `.screenSaver` level so floated windows and the focus overlay can't
/// occlude it.
///
/// AppKit-only, App layer. Driven by `WindowManager.onHudEvent` (event + the target
/// display's visible Cocoa frame) and `onConfigReloaded` (style). Geometry-agnostic: the
/// frame it's handed is already the panel's own (Cocoa) space, so it just centers within it.
final class HudController {
    private let panel: NSPanel
    private let effect: NSVisualEffectView
    private let imageView: NSImageView
    private let label: NSTextField
    private var style: Hud

    /// Bumped on every `show()`, so a fade-out completion (or its dismiss timer) fired for an
    /// earlier bezel can't hide one that was re-shown in the meantime.
    private var generation = 0
    private var dismissTimer: Timer?

    init(style: Hud) {
        self.style = style
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // clicks pass through to whatever's below
        panel.level = .screenSaver               // above .floating: never occluded by a float or the halo
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        imageView = NSImageView()
        imageView.contentTintColor = .labelColor
        label = NSTextField(labelWithString: "")
        label.textColor = .labelColor

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Public API

    /// Flash `event` at the lower center of `visibleFrame` (a display's visible Cocoa frame).
    /// Content swaps instantly on a rapid re-show — no crossfade, matching the native bezel —
    /// while the dismiss clock resets so the hold restarts from the latest change.
    func show(_ event: HudEvent, on visibleFrame: CGRect) {
        guard style.enabled else { return }
        generation &+= 1
        dismissTimer?.invalidate()

        if let image = NSImage(systemSymbolName: event.symbolName, accessibilityDescription: event.title) {
            image.isTemplate = true
            imageView.image = image.withSymbolConfiguration(symbolConfig) ?? image
            imageView.isHidden = false
        } else {
            imageView.image = nil
            imageView.isHidden = true          // unresolved symbol → text only
        }
        label.font = NSFont.systemFont(ofSize: style.fontSize, weight: .medium)
        label.stringValue = event.title

        effect.layoutSubtreeIfNeeded()
        let size = effect.fittingSize
        let origin = Geometry.hudOrigin(size: size, visibleFrame: visibleFrame, bottomOffset: style.bottomOffset)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()           // never steals focus (non-activating)

        fadeIn()
        let gen = generation
        dismissTimer = Timer.scheduledTimer(withTimeInterval: style.hold, repeats: false) { [weak self] _ in
            self?.fadeOut(gen)
        }
    }

    /// Adopt a reloaded config. Disabling cancels any in-flight bezel and hides it right away;
    /// the other metrics take effect on the next `show()`.
    func applyStyle(_ style: Hud) {
        self.style = style
        if !style.enabled { hideNow() }
    }

    // MARK: - Fades

    /// Fade to full opacity. When re-shown mid-fade-out (alpha below 1) the rise is shortened
    /// proportionally, so a rapid toggle snaps back rather than replaying the whole fade-in.
    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = style.fadeIn * Double(1 - panel.alphaValue)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Fade out and order the panel away, but only if no newer `show()` intervened — the
    /// generation guard drops both a superseded dismiss timer and a stale completion.
    private func fadeOut(_ gen: Int) {
        guard gen == generation else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = style.fadeOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.generation else { return }
            self.panel.orderOut(nil)
        })
    }

    /// Cancel everything pending and hide instantly (config disabled, or the display went away).
    private func hideNow() {
        generation &+= 1
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    /// A display change that left the bezel's frame off every screen (its monitor unplugged)
    /// would strand it at a phantom position — hide it instead.
    @objc private func screenParametersChanged() {
        guard panel.isVisible,
              !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) else { return }
        hideNow()
    }

    private var symbolConfig: NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: style.fontSize, weight: .medium)
    }
}
