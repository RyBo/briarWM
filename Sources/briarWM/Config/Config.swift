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

    init() {
        modifier = "alt"
        gaps = Gaps()
        layout = LayoutOptions()
        exec = [:]
        keybindings = [:]
        modes = [:]
        floating = FloatingRules()
        rules = []
    }

    enum CodingKeys: String, CodingKey {
        case modifier, gaps, layout, exec, keybindings, modes, floating, rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modifier = try c.decodeIfPresent(String.self, forKey: .modifier) ?? "alt"
        gaps = try c.decodeIfPresent(Gaps.self, forKey: .gaps) ?? Gaps()
        layout = try c.decodeIfPresent(LayoutOptions.self, forKey: .layout) ?? LayoutOptions()
        exec = try c.decodeIfPresent([String: String].self, forKey: .exec) ?? [:]
        keybindings = try c.decodeIfPresent([String: String].self, forKey: .keybindings) ?? [:]
        modes = try c.decodeIfPresent([String: [String: String]].self, forKey: .modes) ?? [:]
        floating = try c.decodeIfPresent(FloatingRules.self, forKey: .floating) ?? FloatingRules()
        rules = try c.decodeIfPresent([AppRule].self, forKey: .rules) ?? []
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inner = try c.decodeIfPresent(CGFloat.self, forKey: .inner) ?? 10
        outer = try c.decodeIfPresent(CGFloat.self, forKey: .outer) ?? 6
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultRatio = try c.decodeIfPresent(Double.self, forKey: .defaultRatio) ?? 0.5
        insertAt = try c.decodeIfPresent(String.self, forKey: .insertAt) ?? "after"
        autoSplit = try c.decodeIfPresent(String.self, forKey: .autoSplit) ?? "longer_edge"
        focusWrapsMonitors = try c.decodeIfPresent(Bool.self, forKey: .focusWrapsMonitors) ?? true
        moveFollowsFocus = try c.decodeIfPresent(Bool.self, forKey: .moveFollowsFocus) ?? false
        spacePollInterval = try c.decodeIfPresent(Double.self, forKey: .spacePollInterval) ?? 1.5
        presetCycle = try c.decodeIfPresent([String].self, forKey: .presetCycle) ?? LayoutOptions.defaultPresetCycle
        mainRatio = try c.decodeIfPresent(Double.self, forKey: .mainRatio) ?? 0.6
        manageTabbedWindows = try c.decodeIfPresent(Bool.self, forKey: .manageTabbedWindows) ?? true
        reflowOnMinimize = try c.decodeIfPresent(Bool.self, forKey: .reflowOnMinimize) ?? true
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIds = try c.decodeIfPresent([String].self, forKey: .bundleIds) ?? []
        titleRegex = try c.decodeIfPresent([String].self, forKey: .titleRegex) ?? []
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
