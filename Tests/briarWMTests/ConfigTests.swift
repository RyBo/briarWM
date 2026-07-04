import Testing
import Foundation
@testable import briarWM

/// Config decoding is exercised here with JSONDecoder (Decodable is format-agnostic),
/// which keeps these tests independent of the YAML library while still verifying the
/// snake_case CodingKeys and the "missing keys fall back to defaults" behavior.
@Suite struct ConfigTests {

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func emptyConfigUsesAllDefaults() throws {
        let c = try decode("{}")
        #expect(c.modifier == "alt")
        #expect(c.gaps.inner == 10)
        #expect(c.gaps.outer == 6)
        #expect(c.layout.defaultRatio == 0.5)
        #expect(c.layout.insertAt == "after")
        #expect(c.layout.focusWrapsMonitors)
        #expect(c.layout.presetCycle == LayoutOptions.defaultPresetCycle)
        #expect(c.layout.mainRatio == 0.6)
        #expect(c.layout.manageTabbedWindows)
        #expect(c.keybindings.isEmpty)
        #expect(c.rules.isEmpty)
    }

    @Test func layoutPresetOptionsDecode() throws {
        let c = try decode(#"{ "layout": { "preset_cycle": ["tiled", "even-vertical"], "main_ratio": 0.7 } }"#)
        #expect(c.layout.presetCycle == ["tiled", "even-vertical"])
        #expect(c.layout.mainRatio == 0.7)
    }

    @Test func manageTabbedWindowsDecodes() throws {
        #expect(try decode("{}").layout.manageTabbedWindows)                                  // default true
        #expect(!(try decode(#"{ "layout": { "manage_tabbed_windows": false } }"#).layout.manageTabbedWindows))
    }

    @Test func reflowOnMinimizeDecodes() throws {
        #expect(try decode("{}").layout.reflowOnMinimize)                                     // default true
        #expect(!(try decode(#"{ "layout": { "reflow_on_minimize": false } }"#).layout.reflowOnMinimize))
    }

    @Test func focusIndicatorUsesDefaultsWhenOmitted() throws {
        let fi = try decode("{}").focusIndicator
        #expect(fi.enabled)
        #expect(fi.color == HexColor(hex: "#64D2FF"))
        #expect(fi.borderWidth == 1.5)
        #expect(fi.cornerRadius == 6.0)
        #expect(fi.fadeIn == 0.14)
        #expect(fi.hold == 0.0)
        #expect(fi.fadeOut == 0.30)
        #expect(fi.opacity == 0.55)
        #expect(fi.glow == 5.0)
    }

    @Test func focusIndicatorDecodesFullSection() throws {
        let c = try decode("""
        {
          "focus_indicator": {
            "enabled": false, "color": "#FF0000", "border_width": 3,
            "corner_radius": 10, "fade_in": 0.2, "hold": 0.3, "fade_out": 0.5,
            "opacity": 0.7, "glow": 12
          }
        }
        """)
        let fi = c.focusIndicator
        #expect(!fi.enabled)
        #expect(fi.color == HexColor(hex: "#FF0000"))
        #expect(fi.borderWidth == 3)
        #expect(fi.cornerRadius == 10)
        #expect(fi.fadeIn == 0.2)
        #expect(fi.hold == 0.3)
        #expect(fi.fadeOut == 0.5)
        #expect(fi.opacity == 0.7)
        #expect(fi.glow == 12)
    }

    @Test func focusIndicatorPartialSectionKeepsPerKeyDefaults() throws {
        // A partial block: only `color` and `opacity` overridden — the rest keep their
        // single-source defaults (snake_case keys must map).
        let fi = try decode(##"{ "focus_indicator": { "color": "#000000", "opacity": 0.9 } }"##).focusIndicator
        #expect(fi.color == HexColor(hex: "#000000"))
        #expect(fi.opacity == 0.9)
        #expect(fi.enabled)              // default
        #expect(fi.borderWidth == 1.5)   // default
        #expect(fi.fadeIn == 0.14)       // default
    }

    @Test func partialConfigMergesDefaults() throws {
        let c = try decode(#"{ "modifier": "cmd", "gaps": { "inner": 4 } }"#)
        #expect(c.modifier == "cmd")
        #expect(c.gaps.inner == 4)
        #expect(c.gaps.outer == 6)   // unspecified keeps default
    }

    @Test func snakeCaseKeysAndNestedStructures() throws {
        let c = try decode("""
        {
          "layout": { "default_ratio": 0.6, "insert_at": "before" },
          "keybindings": { "alt+h": "focus left" },
          "floating": { "bundle_ids": ["com.apple.systempreferences"], "title_regex": [".*Settings$"] },
          "rules": [ { "match": { "bundle_id": "us.zoom.xos" }, "floating": true } ]
        }
        """)
        #expect(c.layout.defaultRatio == 0.6)
        #expect(c.layout.insertAt == "before")
        #expect(c.keybindings["alt+h"] == "focus left")
        #expect(c.floating.bundleIds == ["com.apple.systempreferences"])
        #expect(c.floating.titleRegex == [".*Settings$"])
        #expect(c.rules.count == 1)
        #expect(c.rules.first?.match.bundleId == "us.zoom.xos")
        #expect(c.rules.first?.floating == true)
    }

    @Test func matchRequiresEverySpecifiedCriterion() {
        let both = Match(bundleId: "com.example.app", titleRegex: "^Palette")
        #expect(both.matches(bundleID: "com.example.app", title: "Palette — Tools"))
        #expect(!both.matches(bundleID: "com.example.app", title: "Document"))
        #expect(!both.matches(bundleID: "com.other.app", title: "Palette — Tools"))

        let byBundle = Match(bundleId: "com.example.app", titleRegex: nil)
        #expect(byBundle.matches(bundleID: "com.example.app", title: nil))

        let byTitle = Match(bundleId: nil, titleRegex: "Settings$")
        #expect(byTitle.matches(bundleID: nil, title: "App Settings"))
        #expect(!byTitle.matches(bundleID: nil, title: nil))

        let empty = Match(bundleId: nil, titleRegex: nil)
        #expect(!empty.matches(bundleID: "com.example.app", title: "anything"))
    }
}
