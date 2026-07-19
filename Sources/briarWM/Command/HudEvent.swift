/// A mode change worth flashing on the transient bezel HUD. PURE (no AppKit): the App
/// layer resolves `symbolName` to an `NSImage` and draws `title`. Each case carries the
/// *resulting* state, so the mutation methods emit it after they flip — a guard-fail path
/// (e.g. splitting a lone window) simply emits nothing.
enum HudEvent: Equatable {
    case preselect(Orientation)
    case splitToggled(Orientation)      // the new orientation after the flip
    case float(on: Bool)
    case zoom(on: Bool)                 // briarWM zoom (zoomedID), not native fullscreen
    case workspaceFloat(on: Bool)
    case focusMode(floating: Bool)      // whether focus landed on a floating window
    case bindingMode(String)            // enter only; exit emits no bezel

    var title: String {
        switch self {
        case .preselect(let o):        return "Preselect: \(o.label)"
        case .splitToggled(let o):     return "Split: \(o.label)"
        case .float(let on):           return on ? "Floating" : "Tiled"
        case .zoom(let on):            return on ? "Zoomed" : "Unzoomed"
        case .workspaceFloat(let on):  return on ? "Desktop: Floating" : "Desktop: Tiled"
        case .focusMode(let floating): return floating ? "Focus: Floating" : "Focus: Tiled"
        case .bindingMode(let name):   return "\(name.capitalized) mode"
        }
    }

    /// An SF Symbol name (resolved by the App layer). All chosen symbols exist on macOS 14.
    var symbolName: String {
        switch self {
        case .preselect(let o), .splitToggled(let o):
            return o == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2"
        case .float(let on):
            return on ? "macwindow.on.rectangle" : "rectangle.grid.2x2"
        case .zoom(let on):
            return on ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
        case .workspaceFloat:
            return "rectangle.on.rectangle"
        case .focusMode(let floating):
            return floating ? "macwindow.on.rectangle" : "rectangle.grid.2x2"
        case .bindingMode:
            return "keyboard"
        }
    }
}

/// The sticky modes the menu-bar item advertises so a state you can't see (zoomed, a lone
/// float, a floated desktop) stays visible. Recomputed at the retile funnel and pushed
/// (deduplicated) to the status item; `suffix` is what gets appended to "🌿".
struct StickyState: Equatable {
    var zoomed = false
    var focusedFloating = false
    var workspaceFloating = false

    /// The glyphs for the active sticky modes, composed in a fixed order (zoom, focused
    /// float, workspace float) so the suffix is stable regardless of which turned on first.
    var suffix: String {
        var s = ""
        if zoomed { s += "⛶" }
        if focusedFloating { s += "~" }
        if workspaceFloating { s += "≈" }
        return s
    }
}

private extension Orientation {
    var label: String { self == .horizontal ? "Horizontal" : "Vertical" }
}
