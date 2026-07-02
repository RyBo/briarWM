import Testing
@testable import briarWM

@Suite struct ConfigValidatorTests {

    @Test func defaultConfigIsClean() {
        #expect(ConfigValidator.issues(in: Config()).isEmpty)
    }

    @Test func unknownModifierIsFlagged() {
        var c = Config()
        c.modifier = "meta-super"
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("modifier"))
        #expect(issues[0].contains("meta-super"))
    }

    @Test func knownModifierAliasesAreClean() {
        for name in ["alt", "Option", "cmd", "SUPER", "win", "meta", "ctrl", "shift", "hyper"] {
            var c = Config()
            c.modifier = name
            #expect(ConfigValidator.issues(in: c).isEmpty, "\(name) should be accepted")
        }
    }

    @Test func negativeSpacePollIntervalIsFlagged() {
        var c = Config()
        c.layout.spacePollInterval = -1
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("space_poll_interval"))
    }

    @Test func badInsertAtAndAutoSplitAreFlagged() {
        var c = Config()
        c.layout.insertAt = "afterr"
        c.layout.autoSplit = "diagonal"
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 2)
        #expect(issues.contains { $0.contains("insert_at") && $0.contains("afterr") })
        #expect(issues.contains { $0.contains("auto_split") && $0.contains("diagonal") })
    }

    @Test func unknownPresetTokenIsFlagged() {
        var c = Config()
        c.layout.presetCycle = ["even-horizontal", "spiral", "tiled"]
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("spiral"))
    }

    @Test func outOfRangeRatiosAreFlagged() {
        var c = Config()
        c.layout.defaultRatio = 0
        c.layout.mainRatio = 1.2
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 2)
        #expect(issues.contains { $0.contains("default_ratio") })
        #expect(issues.contains { $0.contains("main_ratio") })
    }

    @Test func invalidBindingKeyIsFlaggedByName() {
        var c = Config()
        c.keybindings = ["alt+notakey": "focus left"]
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("alt+notakey"))
        #expect(issues[0].contains("key combo"))
    }

    @Test func invalidActionIsFlaggedWithBindingAndValue() {
        var c = Config()
        c.keybindings = ["alt+h": "focsu left"]
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("alt+h"))
        #expect(issues[0].contains("focsu left"))
    }

    @Test func undefinedModeReferenceIsFlagged() {
        var c = Config()
        c.keybindings = ["alt+r": "mode resize"]   // no modes.resize defined
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("resize"))
        #expect(issues[0].contains("modes"))
    }

    @Test func definedModeReferenceIsClean() {
        var c = Config()
        c.keybindings = ["alt+r": "mode resize"]
        c.modes = ["resize": ["escape": "mode default", "h": "resize left 40"]]
        #expect(ConfigValidator.issues(in: c).isEmpty)
    }

    @Test func modeBindingsAreValidatedWithModeContext() {
        var c = Config()
        c.modes = ["resize": ["h": "resiez left"]]
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("modes.resize"))
    }

    @Test func badRegexesAreFlagged() {
        var c = Config()
        c.floating.titleRegex = ["^Preferences$", "(unclosed"]
        c.rules = [AppRule(match: Match(bundleId: nil, titleRegex: "[bad"), floating: true)]
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 2)
        #expect(issues.contains { $0.contains("(unclosed") })
        #expect(issues.contains { $0.contains("[bad") })
    }

    @Test func emptyRuleMatchIsFlagged() {
        var c = Config()
        c.rules = [AppRule(match: Match(bundleId: nil, titleRegex: nil), floating: true)]
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("no match criteria"))
    }
}
