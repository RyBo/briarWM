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

    @Test func validFocusIndicatorIsClean() {
        #expect(ConfigValidator.issues(in: Config()).isEmpty)   // defaults
        var c = Config()
        c.focusIndicator = FocusIndicator(borderWidth: 0, opacity: 0, glow: 0)
        #expect(ConfigValidator.issues(in: c).isEmpty)          // zero is allowed, just not negative
    }

    @Test func negativeFocusIndicatorMetricsAreFlagged() {
        var c = Config()
        c.focusIndicator = FocusIndicator(borderWidth: -1, cornerRadius: -2, fadeIn: -0.1,
                                          fadeOut: -0.2, glow: -3)
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.contains { $0.contains("border_width") })
        #expect(issues.contains { $0.contains("corner_radius") })
        #expect(issues.contains { $0.contains("fade_in") })
        #expect(issues.contains { $0.contains("fade_out") })
        #expect(issues.contains { $0.contains("glow") })
    }

    @Test func outOfRangeOpacityIsFlagged() {
        for bad in [-0.1, 1.5] {
            var c = Config()
            c.focusIndicator = FocusIndicator(opacity: bad)
            let issues = ConfigValidator.issues(in: c)
            #expect(issues.count == 1)
            #expect(issues[0].contains("opacity"))
        }
    }

    @Test func outOfRangeRestOpacityIsFlagged() {
        for bad in [-0.1, 1.5] {
            var c = Config()
            c.focusIndicator = FocusIndicator(restOpacity: bad)
            let issues = ConfigValidator.issues(in: c)
            #expect(issues.count == 1)
            #expect(issues[0].contains("rest_opacity"))
        }
    }

    @Test func boundaryRestOpacityIsClean() {
        for ok in [0.0, 1.0] {
            var c = Config()
            c.focusIndicator = FocusIndicator(restOpacity: ok)
            #expect(ConfigValidator.issues(in: c).isEmpty)   // 0 and 1 are in range
        }
    }

    @Test func emptyRuleMatchIsFlagged() {
        var c = Config()
        c.rules = [AppRule(match: Match(bundleId: nil, titleRegex: nil), floating: true)]
        let issues = ConfigValidator.issues(in: c)
        #expect(issues.count == 1)
        #expect(issues[0].contains("no match criteria"))
    }
}
