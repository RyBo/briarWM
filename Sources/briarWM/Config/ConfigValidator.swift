import Foundation

/// Semantic validation of a decoded `Config`: catches values that YAML decoding accepts
/// but the runtime would silently ignore or replace with a default — typo'd modifier
/// names, unknown enum strings, bindings that don't parse, uncompilable regexes.
/// PURE (Foundation only), shared by `--check-config`, load-time warnings, and tests.
enum ConfigValidator {
    static func issues(in config: Config) -> [String] {
        var out: [String] = []

        if !Keycodes.knownModifierNames.contains(config.modifier.lowercased()) {
            out.append("modifier: unknown name \"\(config.modifier)\" (would silently fall back to alt)")
        }
        if InsertAt(rawValue: config.layout.insertAt) == nil {
            out.append("layout.insert_at: \"\(config.layout.insertAt)\" is not \"after\" or \"before\"")
        }
        if AutoSplit(token: config.layout.autoSplit) == nil {
            out.append("layout.auto_split: \"\(config.layout.autoSplit)\" is not \"longer_edge\", \"horizontal\" or \"vertical\"")
        }
        for token in config.layout.presetCycle where LayoutPreset(token: token) == nil {
            out.append("layout.preset_cycle: unknown preset \"\(token)\"")
        }
        for (name, ratio) in [("layout.default_ratio", config.layout.defaultRatio),
                              ("layout.main_ratio", config.layout.mainRatio)] where !(ratio > 0 && ratio < 1) {
            out.append("\(name): \(ratio) is outside (0, 1)")
        }
        if config.layout.spacePollInterval < 0 {
            out.append("layout.space_poll_interval: negative disables the backstop poll — use 0 to disable explicitly")
        }

        let fi = config.focusIndicator
        for (name, value) in [("focus_indicator.border_width", fi.borderWidth),
                              ("focus_indicator.corner_radius", fi.cornerRadius),
                              ("focus_indicator.glow", fi.glow)] where value < 0 {
            out.append("\(name): \(value) is negative")
        }
        for (name, value) in [("focus_indicator.fade_in", fi.fadeIn),
                              ("focus_indicator.hold", fi.hold),
                              ("focus_indicator.fade_out", fi.fadeOut)] where value < 0 {
            out.append("\(name): \(value) is negative")
        }
        if !(fi.opacity >= 0 && fi.opacity <= 1) {
            out.append("focus_indicator.opacity: \(fi.opacity) is outside [0, 1]")
        }
        if !(fi.restOpacity >= 0 && fi.restOpacity <= 1) {
            out.append("focus_indicator.rest_opacity: \(fi.restOpacity) is outside [0, 1]")
        }

        out += bindingIssues(config.keybindings, context: "keybindings", config: config)
        for (name, binds) in config.modes.sorted(by: { $0.key < $1.key }) {
            out += bindingIssues(binds, context: "modes.\(name)", config: config)
        }

        for pattern in config.floating.titleRegex where !isValidRegex(pattern) {
            out.append("floating.title_regex: invalid pattern \"\(pattern)\"")
        }
        for rule in config.rules {
            if let pattern = rule.match.titleRegex, !isValidRegex(pattern) {
                out.append("rules: invalid title_regex \"\(pattern)\"")
            }
            if rule.match.bundleId == nil && rule.match.titleRegex == nil {
                out.append("rules: a rule has no match criteria (needs bundle_id and/or title_regex)")
            }
        }
        return out
    }

    private static func bindingIssues(_ binds: [String: String], context: String, config: Config) -> [String] {
        var out: [String] = []
        for (key, value) in binds.sorted(by: { $0.key < $1.key }) {
            if KeyCombo.parse(key, defaultMod: config.modifier) == nil {
                out.append("\(context): \"\(key)\" is not a valid key combo")
            }
            guard let action = Action.parse(value) else {
                out.append("\(context): \"\(key)\" has unknown action \"\(value)\"")
                continue
            }
            if case .enterMode(let mode) = action, config.modes[mode] == nil {
                out.append("\(context): \"\(key)\" enters mode \"\(mode)\", which is not defined under modes")
            }
        }
        return out
    }

    private static func isValidRegex(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }
}
