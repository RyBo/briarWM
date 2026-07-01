import Foundation
import Yams

/// Loads and decodes the YAML config.
enum ConfigLoader {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/briarWM/config.yaml")
    }

    /// Load the user config. A missing file is a valid state (defaults); a file that
    /// exists but fails to read or parse throws, so callers that already hold a working
    /// config (hot reload) can keep it instead of silently reverting to defaults.
    static func load() throws -> Config {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.logger.info("no config at \(url.path); using defaults")
            return Config()
        }
        let config = try load(from: url)
        // Values that decode fine but would be silently ignored at runtime — warn once here.
        for issue in ConfigValidator.issues(in: config) {
            Log.logger.warning("config: \(issue)")
        }
        return config
    }

    /// Decode a specific config file, throwing on read/parse failure.
    static func load(from url: URL) throws -> Config {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(Config.self, from: text)
    }
}
