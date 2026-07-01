import Testing
@testable import briarWM

@Suite struct KeymapTests {

    private func config(modifier: String = "alt",
                        keybindings: [String: String] = [:],
                        modes: [String: [String: String]] = [:]) -> Config {
        var c = Config()
        c.modifier = modifier
        c.keybindings = keybindings
        c.modes = modes
        return c
    }

    @Test func compilesValidBindingsAndDropsInvalidOnes() {
        let keymap = Keymap(config: config(keybindings: [
            "alt+h": "focus left",          // valid
            "alt+notakey": "focus right",   // invalid key → dropped
            "alt+j": "not an action",       // invalid action → dropped
        ]))
        let combos = keymap.combos(for: Keymap.defaultMode)
        #expect(combos.count == 1)
        #expect(keymap.action(for: combos[0], mode: Keymap.defaultMode) == .focus(.left))
    }

    @Test func modResolvesToConfiguredModifier() {
        let keymap = Keymap(config: config(modifier: "cmd", keybindings: ["$mod+h": "focus left"]))
        let expected = KeyCombo.parse("cmd+h", defaultMod: "cmd")
        #expect(expected != nil)
        #expect(keymap.action(for: expected!, mode: Keymap.defaultMode) == .focus(.left))
    }

    @Test func modesCompileIndependentlyOfDefault() {
        let keymap = Keymap(config: config(
            keybindings: ["alt+r": "mode resize"],
            modes: ["resize": ["h": "resize left 40", "escape": "mode default"]]))
        #expect(keymap.hasMode("resize"))
        #expect(!keymap.hasMode("nonexistent"))
        #expect(keymap.combos(for: "resize").count == 2)
        // Bare keys inside a mode are valid combos with no modifier.
        let h = KeyCombo.parse("h", defaultMod: "alt")!
        #expect(keymap.action(for: h, mode: "resize") == .resize(.left, 40))
        #expect(keymap.action(for: h, mode: Keymap.defaultMode) == nil)
    }

    @Test func unknownModeHasNoCombos() {
        let keymap = Keymap(config: config(keybindings: ["alt+h": "focus left"]))
        #expect(keymap.combos(for: "resize").isEmpty)
    }
}
