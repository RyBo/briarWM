import ApplicationServices

/// Accessibility (TCC) permission helpers.
enum PermissionGate {
    /// Whether briarWM is trusted for the Accessibility API. Pass `prompt: true` to
    /// surface the system "open System Settings" dialog when it isn't.
    static func isTrusted(prompt: Bool) -> Bool {
        // Use the literal key to avoid the Unmanaged/CFString import ambiguity of the
        // kAXTrustedCheckOptionPrompt global across SDK versions.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
