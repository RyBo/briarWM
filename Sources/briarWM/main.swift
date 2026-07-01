import AppKit
import Foundation
import Logging

// briarWM — a simple macOS BSP tiling window manager.
// Runs as an accessory (no Dock icon) on the main run loop, which AX observers
// and Carbon hotkeys both require.

// Log level defaults to info; set BRIARWM_LOG=debug (or trace/warning/error) for verbose
// diagnostics, e.g. tab adopt/rebind/ignore decisions.
let logLevel = ProcessInfo.processInfo.environment["BRIARWM_LOG"]
    .flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info
Log.bootstrap(level: logLevel)

// `briarWM --check-config [path]` validates a config file and exits without
// touching any windows. Defaults to ~/.config/briarWM/config.yaml.
if CommandLine.arguments.contains("--check-config") {
    let args = CommandLine.arguments
    let url: URL = {
        if let i = args.firstIndex(of: "--check-config"), i + 1 < args.count, !args[i + 1].hasPrefix("-") {
            return URL(fileURLWithPath: args[i + 1])
        }
        return ConfigLoader.configURL
    }()
    do {
        let cfg = try ConfigLoader.load(from: url)
        let issues = ConfigValidator.issues(in: cfg)
        guard issues.isEmpty else {
            var msg = "❌ \(url.lastPathComponent): \(issues.count) issue(s)\n"
            for issue in issues { msg += "   • \(issue)\n" }
            FileHandle.standardError.write(Data(msg.utf8))
            exit(1)
        }
        let keymap = Keymap(config: cfg)
        print("✅ \(url.lastPathComponent) OK")
        print("   modifier: \(cfg.modifier)  gaps: inner=\(cfg.gaps.inner) outer=\(cfg.gaps.outer)")
        print("   bindings: \(keymap.combos(for: Keymap.defaultMode).count) in default mode, \(cfg.modes.count) extra mode(s)")
        print("   floating: \(cfg.floating.bundleIds.count) bundle id(s), \(cfg.floating.titleRegex.count) title rule(s)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("❌ \(url.path): \(error)\n".utf8))
        exit(1)
    }
}

Log.logger.info("briarWM starting")

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
