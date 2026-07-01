import AppKit

/// Re-exec the current binary with the same arguments and terminate this instance.
/// Used when Accessibility is granted mid-run (AX clients created before the grant
/// stay broken) and by the `restart` command.
enum Relaunch {
    static func now() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        proc.arguments = Array(CommandLine.arguments.dropFirst())
        try? proc.run()
        NSApp.terminate(nil)
    }
}
