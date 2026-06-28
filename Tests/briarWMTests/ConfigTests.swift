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
        #expect(c.gaps.mode == "simple")
        #expect(c.layout.defaultRatio == 0.5)
        #expect(c.layout.insertAt == "after")
        #expect(c.layout.focusWrapsMonitors)
        #expect(!c.layout.focusFollowsMouse)
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

    @Test func partialConfigMergesDefaults() throws {
        let c = try decode(#"{ "modifier": "cmd", "gaps": { "inner": 4 } }"#)
        #expect(c.modifier == "cmd")
        #expect(c.gaps.inner == 4)
        #expect(c.gaps.outer == 6)   // unspecified keeps default
    }

    @Test func snakeCaseKeysAndNestedStructures() throws {
        let c = try decode("""
        {
          "layout": { "default_ratio": 0.6, "insert_at": "before", "focus_follows_mouse": true },
          "keybindings": { "alt+h": "focus left" },
          "floating": { "bundle_ids": ["com.apple.systempreferences"], "title_regex": [".*Settings$"] },
          "rules": [ { "match": { "bundle_id": "us.zoom.xos" }, "floating": true } ]
        }
        """)
        #expect(c.layout.defaultRatio == 0.6)
        #expect(c.layout.insertAt == "before")
        #expect(c.layout.focusFollowsMouse)
        #expect(c.keybindings["alt+h"] == "focus left")
        #expect(c.floating.bundleIds == ["com.apple.systempreferences"])
        #expect(c.floating.titleRegex == [".*Settings$"])
        #expect(c.rules.count == 1)
        #expect(c.rules.first?.match.bundleId == "us.zoom.xos")
        #expect(c.rules.first?.floating == true)
    }
}
