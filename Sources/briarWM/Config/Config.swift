import CoreGraphics
import Foundation

/// The full briarWM configuration, decoded from YAML. Every field has a default so
/// a missing/partial config is always valid (Decodable with `decodeIfPresent`).
struct Config: Decodable, Equatable {
    var modifier: String
    var gaps: Gaps
    var layout: LayoutOptions
    var exec: [String: String]
    var keybindings: [String: String]
    var modes: [String: [String: String]]
    var floating: FloatingRules
    var rules: [AppRule]
    var focusIndicator: FocusIndicator

    init() {
        modifier = "alt"
        gaps = Gaps()
        layout = LayoutOptions()
        exec = [:]
        keybindings = [:]
        modes = [:]
        floating = FloatingRules()
        rules = []
        focusIndicator = FocusIndicator()
    }

    enum CodingKeys: String, CodingKey {
        case modifier, gaps, layout, exec, keybindings, modes, floating, rules
        case focusIndicator = "focus_indicator"
    }

    init(from decoder: Decoder) throws {
        // Single-source the defaults: `d` holds the memberwise-init defaults, so every
        // missing key falls back to `d.field` rather than a duplicated literal. (Same
        // pattern in Gaps / LayoutOptions / FloatingRules below.)
        let d = Self()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modifier = try c.decodeIfPresent(String.self, forKey: .modifier) ?? d.modifier
        gaps = try c.decodeIfPresent(Gaps.self, forKey: .gaps) ?? d.gaps
        layout = try c.decodeIfPresent(LayoutOptions.self, forKey: .layout) ?? d.layout
        exec = try c.decodeIfPresent([String: String].self, forKey: .exec) ?? d.exec
        keybindings = try c.decodeIfPresent([String: String].self, forKey: .keybindings) ?? d.keybindings
        modes = try c.decodeIfPresent([String: [String: String]].self, forKey: .modes) ?? d.modes
        floating = try c.decodeIfPresent(FloatingRules.self, forKey: .floating) ?? d.floating
        rules = try c.decodeIfPresent([AppRule].self, forKey: .rules) ?? d.rules
        focusIndicator = try c.decodeIfPresent(FocusIndicator.self, forKey: .focusIndicator) ?? d.focusIndicator
    }
}

/// An sRGB color parsed from a `#RGB` / `#RRGGBB` / `#RRGGBBAA` hex string. PURE (no
/// AppKit) so hex parsing is unit-testable in the pure suite; the App layer converts it
/// to `NSColor` when it draws.
struct HexColor: Decodable, Equatable {
    let r, g, b, a: Double   // each 0…1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = HexColor(hex: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "invalid hex color \"\(raw)\" (expected #RGB, #RRGGBB, or #RRGGBBAA)"))
        }
        self = parsed
    }

    /// Parse `#RGB` / `#RRGGBB` / `#RRGGBBAA` (the leading `#` is optional). Returns nil on
    /// any malformed input — wrong length or a non-hex digit.
    init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        let d = Array(s)
        // ASCII hex only. `Character.isHexDigit` also accepts fullwidth compatibility forms
        // (e.g. "Ｆ" U+FF26) that `Int(_:radix:)` refuses — letting those past the gate would
        // trap on the force-unwraps in byte()/nibble() and crash config load/hot-reload.
        guard d.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }

        func byte(_ chars: ArraySlice<Character>) -> Double { Double(Int(String(chars), radix: 16)!) / 255 }
        func nibble(_ c: Character) -> Double { Double(Int(String(c), radix: 16)! * 17) / 255 }

        switch d.count {
        case 3:   // #RGB → each nibble doubled
            self.init(r: nibble(d[0]), g: nibble(d[1]), b: nibble(d[2]))
        case 4:   // #RGBA
            self.init(r: nibble(d[0]), g: nibble(d[1]), b: nibble(d[2]), a: nibble(d[3]))
        case 6:
            self.init(r: byte(d[0..<2]), g: byte(d[2..<4]), b: byte(d[4..<6]))
        case 8:
            self.init(r: byte(d[0..<2]), g: byte(d[2..<4]), b: byte(d[4..<6]), a: byte(d[6..<8]))
        default:
            return nil
        }
    }
}

/// The focus-indicator overlay: a soft glowing border that gives a single quick bounce
/// (rise → optional hold → fall) on each focus switch, dimmed below full opacity and
/// feathered by `glow` so it reads as a gentle pulse of light rather than a hard rectangle.
/// Follows the `Gaps` template (memberwise-init defaults + snake_case CodingKeys + the
/// `let d = Self()` single-source-defaults decoder). All metrics are AppKit-free so the whole
/// struct stays in the pure Config layer; `FocusOverlayController` turns `color` into an
/// `NSColor` to draw.
struct FocusIndicator: Decodable, Equatable {
    var enabled: Bool
    var color: HexColor        // border accent
    var borderWidth: CGFloat
    var cornerRadius: CGFloat
    var fadeIn: Double         // seconds
    var hold: Double
    var fadeOut: Double
    /// Peak opacity the bounce reaches, 0…1. Below 1 so the cue reads as a gentle pulse
    /// rather than a hard flash.
    var opacity: Double
    /// Resting opacity the border settles at between pulses, 0…1. `0` (default) = the border
    /// is invisible except during the pulse; `>0` = a persistent border that swells from this
    /// rest level up to `opacity` on each focus switch and back down.
    var restOpacity: Double
    /// Soft same-color glow feathering the stroke, in points (0 = a crisp hard line). This
    /// is what turns the border from a stark rectangle into a soft rim of light.
    var glow: CGFloat

    init(enabled: Bool = true,
         color: HexColor = HexColor(r: 0x64 / 255, g: 0xD2 / 255, b: 0xFF / 255),  // #64D2FF macOS systemTeal
         borderWidth: CGFloat = 1.5,
         cornerRadius: CGFloat = 6.0,
         fadeIn: Double = 0.14,
         hold: Double = 0.0,
         fadeOut: Double = 0.30,
         opacity: Double = 0.55,
         restOpacity: Double = 0.0,
         glow: CGFloat = 5.0) {
        self.enabled = enabled
        self.color = color
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.fadeIn = fadeIn
        self.hold = hold
        self.fadeOut = fadeOut
        self.opacity = opacity
        self.restOpacity = restOpacity
        self.glow = glow
    }

    enum CodingKeys: String, CodingKey {
        case enabled, color, hold, opacity, glow
        case borderWidth = "border_width"
        case cornerRadius = "corner_radius"
        case fadeIn = "fade_in"
        case fadeOut = "fade_out"
        case restOpacity = "rest_opacity"
    }

    init(from decoder: Decoder) throws {
        let d = Self()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        color = try c.decodeIfPresent(HexColor.self, forKey: .color) ?? d.color
        borderWidth = try c.decodeIfPresent(CGFloat.self, forKey: .borderWidth) ?? d.borderWidth
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? d.cornerRadius
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? d.fadeIn
        hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? d.hold
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? d.fadeOut
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        restOpacity = try c.decodeIfPresent(Double.self, forKey: .restOpacity) ?? d.restOpacity
        glow = try c.decodeIfPresent(CGFloat.self, forKey: .glow) ?? d.glow
    }
}

struct Gaps: Decodable, Equatable {
    var inner: CGFloat
    var outer: CGFloat

    init(inner: CGFloat = 10, outer: CGFloat = 6) {
        self.inner = inner; self.outer = outer
    }

    enum CodingKeys: String, CodingKey { case inner, outer }

    init(from decoder: Decoder) throws {
        let d = Self()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inner = try c.decodeIfPresent(CGFloat.self, forKey: .inner) ?? d.inner
        outer = try c.decodeIfPresent(CGFloat.self, forKey: .outer) ?? d.outer
    }
}

struct LayoutOptions: Decodable, Equatable {
    var defaultRatio: Double
    var insertAt: String        // "after" | "before"
    var autoSplit: String       // "longer_edge" | "horizontal" | "vertical"
    var focusWrapsMonitors: Bool
    /// When true, `move workspace N` follows the window to that desktop. Default false
    /// (matches i3's "move container to workspace").
    var moveFollowsFocus: Bool
    /// Seconds between background reconciliation sweeps that catch windows dragged to
    /// another desktop without a Space switch (those fire no AX/Space notification).
    /// `0` disables the backstop. Default 1.5s.
    var spacePollInterval: Double
    /// Preset names the `cycle layout` hotkey steps through, in order. Unknown names
    /// are ignored at runtime. Kept as `[String]` so Config stays decoupled from the
    /// `LayoutPreset` enum.
    var presetCycle: [String]
    /// Fraction of the screen the main pane takes in the `main-vertical`/`main-horizontal`
    /// presets. Default 0.6.
    var mainRatio: Double
    /// Treat native macOS window tabs (e.g. Ghostty) as a single tile that follows the
    /// visible tab, instead of tiling every background tab separately. Default true; set
    /// false to fall back to the old one-tile-per-window behavior.
    var manageTabbedWindows: Bool
    /// When true, minimizing a window removes it from the tiling and reflows the
    /// remaining windows to fill the space (restored on un-minimize) — matching
    /// yabai/Amethyst/AeroSpace. Default true; set false to leave the window's slot empty.
    var reflowOnMinimize: Bool

    /// Default `cycle layout` order: the full tmux preset set.
    static let defaultPresetCycle = ["even-horizontal", "even-vertical",
                                     "main-vertical", "main-horizontal", "tiled"]

    init(defaultRatio: Double = 0.5,
         insertAt: String = "after",
         autoSplit: String = "longer_edge",
         focusWrapsMonitors: Bool = true,
         moveFollowsFocus: Bool = false,
         spacePollInterval: Double = 1.5,
         presetCycle: [String] = LayoutOptions.defaultPresetCycle,
         mainRatio: Double = 0.6,
         manageTabbedWindows: Bool = true,
         reflowOnMinimize: Bool = true) {
        self.defaultRatio = defaultRatio
        self.insertAt = insertAt
        self.autoSplit = autoSplit
        self.focusWrapsMonitors = focusWrapsMonitors
        self.moveFollowsFocus = moveFollowsFocus
        self.spacePollInterval = spacePollInterval
        self.presetCycle = presetCycle
        self.mainRatio = mainRatio
        self.manageTabbedWindows = manageTabbedWindows
        self.reflowOnMinimize = reflowOnMinimize
    }

    enum CodingKeys: String, CodingKey {
        case defaultRatio = "default_ratio"
        case insertAt = "insert_at"
        case autoSplit = "auto_split"
        case focusWrapsMonitors = "focus_wraps_monitors"
        case moveFollowsFocus = "move_follows_focus"
        case spacePollInterval = "space_poll_interval"
        case presetCycle = "preset_cycle"
        case mainRatio = "main_ratio"
        case manageTabbedWindows = "manage_tabbed_windows"
        case reflowOnMinimize = "reflow_on_minimize"
    }

    init(from decoder: Decoder) throws {
        let d = Self()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultRatio = try c.decodeIfPresent(Double.self, forKey: .defaultRatio) ?? d.defaultRatio
        insertAt = try c.decodeIfPresent(String.self, forKey: .insertAt) ?? d.insertAt
        autoSplit = try c.decodeIfPresent(String.self, forKey: .autoSplit) ?? d.autoSplit
        focusWrapsMonitors = try c.decodeIfPresent(Bool.self, forKey: .focusWrapsMonitors) ?? d.focusWrapsMonitors
        moveFollowsFocus = try c.decodeIfPresent(Bool.self, forKey: .moveFollowsFocus) ?? d.moveFollowsFocus
        spacePollInterval = try c.decodeIfPresent(Double.self, forKey: .spacePollInterval) ?? d.spacePollInterval
        presetCycle = try c.decodeIfPresent([String].self, forKey: .presetCycle) ?? d.presetCycle
        mainRatio = try c.decodeIfPresent(Double.self, forKey: .mainRatio) ?? d.mainRatio
        manageTabbedWindows = try c.decodeIfPresent(Bool.self, forKey: .manageTabbedWindows) ?? d.manageTabbedWindows
        reflowOnMinimize = try c.decodeIfPresent(Bool.self, forKey: .reflowOnMinimize) ?? d.reflowOnMinimize
    }
}

struct FloatingRules: Decodable, Equatable {
    var bundleIds: [String]
    var titleRegex: [String]

    init(bundleIds: [String] = [], titleRegex: [String] = []) {
        self.bundleIds = bundleIds; self.titleRegex = titleRegex
    }

    enum CodingKeys: String, CodingKey {
        case bundleIds = "bundle_ids"
        case titleRegex = "title_regex"
    }

    init(from decoder: Decoder) throws {
        let d = Self()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIds = try c.decodeIfPresent([String].self, forKey: .bundleIds) ?? d.bundleIds
        titleRegex = try c.decodeIfPresent([String].self, forKey: .titleRegex) ?? d.titleRegex
    }
}

struct AppRule: Decodable, Equatable {
    var match: Match
    var floating: Bool?
}

struct Match: Decodable, Equatable {
    var bundleId: String?
    var titleRegex: String?

    enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case titleRegex = "title_regex"
    }

    /// True when every criterion the rule specifies matches. A criterion left unset is
    /// ignored; a match with no criteria matches nothing (a rule must select something).
    func matches(bundleID: String?, title: String?) -> Bool {
        guard bundleId != nil || titleRegex != nil else { return false }
        if let want = bundleId, want != bundleID { return false }
        if let pattern = titleRegex {
            guard let title, title.range(of: pattern, options: .regularExpression) != nil else { return false }
        }
        return true
    }
}
