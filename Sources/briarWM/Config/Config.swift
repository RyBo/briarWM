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
    var mode: String      // "simple" | "i3"
    var inner: CGFloat
    var outer: CGFloat

    init(mode: String = "simple", inner: CGFloat = 10, outer: CGFloat = 6) {
        self.mode = mode; self.inner = inner; self.outer = outer
    }

    enum CodingKeys: String, CodingKey { case mode, inner, outer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "simple"
        inner = try c.decodeIfPresent(CGFloat.self, forKey: .inner) ?? 10
        outer = try c.decodeIfPresent(CGFloat.self, forKey: .outer) ?? 6
    }
}

struct LayoutOptions: Decodable, Equatable {
    var defaultRatio: Double
    var insertAt: String        // "after" | "before"
    var autoSplit: String       // "longer_edge" | "horizontal" | "vertical"
    var focusWrapsMonitors: Bool
    var focusFollowsMouse: Bool
    /// When true, `move workspace N` follows the window to that desktop. Default false
    /// (matches i3's "move container to workspace").
    var moveFollowsFocus: Bool
    /// Seconds between background reconciliation sweeps that catch windows dragged to
    /// another desktop without a Space switch (those fire no AX/Space notification).
    /// `0` disables the backstop. Default 1.5s.
    var spacePollInterval: Double

    init(defaultRatio: Double = 0.5,
         insertAt: String = "after",
         autoSplit: String = "longer_edge",
         focusWrapsMonitors: Bool = true,
         focusFollowsMouse: Bool = false,
         moveFollowsFocus: Bool = false,
         spacePollInterval: Double = 1.5) {
        self.defaultRatio = defaultRatio
        self.insertAt = insertAt
        self.autoSplit = autoSplit
        self.focusWrapsMonitors = focusWrapsMonitors
        self.focusFollowsMouse = focusFollowsMouse
        self.moveFollowsFocus = moveFollowsFocus
        self.spacePollInterval = spacePollInterval
    }

    enum CodingKeys: String, CodingKey {
        case defaultRatio = "default_ratio"
        case insertAt = "insert_at"
        case autoSplit = "auto_split"
        case focusWrapsMonitors = "focus_wraps_monitors"
        case focusFollowsMouse = "focus_follows_mouse"
        case moveFollowsFocus = "move_follows_focus"
        case spacePollInterval = "space_poll_interval"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultRatio = try c.decodeIfPresent(Double.self, forKey: .defaultRatio) ?? 0.5
        insertAt = try c.decodeIfPresent(String.self, forKey: .insertAt) ?? "after"
        autoSplit = try c.decodeIfPresent(String.self, forKey: .autoSplit) ?? "longer_edge"
        focusWrapsMonitors = try c.decodeIfPresent(Bool.self, forKey: .focusWrapsMonitors) ?? true
        focusFollowsMouse = try c.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse) ?? false
        moveFollowsFocus = try c.decodeIfPresent(Bool.self, forKey: .moveFollowsFocus) ?? false
        spacePollInterval = try c.decodeIfPresent(Double.self, forKey: .spacePollInterval) ?? 1.5
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
    var manage: Bool?
}

struct Match: Decodable, Equatable {
    var bundleId: String?
    var titleRegex: String?

    enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case titleRegex = "title_regex"
    }
}
