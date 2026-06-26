/// Compiled key bindings: per-mode maps from a resolved `KeyCombo` to an `Action`.
/// Built from `Config`; invalid bindings are logged and dropped (never fatal).
struct Keymap {
    static let defaultMode = "default"

    private let modes: [String: [KeyCombo: Action]]

    init(config: Config) {
        var built: [String: [KeyCombo: Action]] = [:]
        built[Keymap.defaultMode] = Keymap.compile(config.keybindings, defaultMod: config.modifier)
        for (name, binds) in config.modes {
            built[name] = Keymap.compile(binds, defaultMod: config.modifier)
        }
        self.modes = built
    }

    func combos(for mode: String) -> [KeyCombo] {
        Array((modes[mode] ?? [:]).keys)
    }

    func action(for combo: KeyCombo, mode: String) -> Action? {
        modes[mode]?[combo]
    }

    func hasMode(_ name: String) -> Bool { modes[name] != nil }

    private static func compile(_ binds: [String: String], defaultMod: String) -> [KeyCombo: Action] {
        var out: [KeyCombo: Action] = [:]
        for (keyString, actionString) in binds {
            guard let combo = KeyCombo.parse(keyString, defaultMod: defaultMod) else {
                Log.logger.warning("invalid key binding key: \(keyString)")
                continue
            }
            guard let action = Action.parse(actionString) else {
                Log.logger.warning("invalid action for \(keyString): \(actionString)")
                continue
            }
            out[combo] = action
        }
        return out
    }
}
