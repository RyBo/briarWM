import Foundation
import Yams

/// Loads and decodes the YAML config, falling back to defaults on any error.
enum ConfigLoader {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/briarWM/config.yaml")
    }

    static func load() -> Config {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.logger.info("no config at \(url.path); using defaults")
            return Config()
        }
        do {
            return try load(from: url)
        } catch {
            Log.logger.error("config parse error (\(error)); keeping defaults")
            return Config()
        }
    }

    /// Decode a specific config file, throwing on read/parse failure.
    static func load(from url: URL) throws -> Config {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(Config.self, from: text)
    }
}
