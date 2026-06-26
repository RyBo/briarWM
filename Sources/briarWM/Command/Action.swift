import CoreGraphics

/// Every command briarWM can perform, parsed from a config binding value such as
/// `"focus left"`, `"resize right 40"`, `"exec terminal"`, `"mode resize"`.
enum Action: Equatable {
    case focus(Direction)
    case move(Direction)
    case resize(Direction, CGFloat)
    case preselect(Orientation)
    case toggleSplit
    case balance
    case fullscreen
    case toggleFloat
    case focusModeToggle
    case close
    case workspace(Int)        // switch to desktop N (1-based, per the focused display)
    case moveToWorkspace(Int)  // send the focused window to desktop N (1-based)
    case exec(String)        // an `exec` key (e.g. "terminal") or a raw command
    case reload
    case restart
    case enterMode(String)
    case exitMode
    case dumpTree
}

extension Action {
    static let defaultResizeStep: CGFloat = 40

    /// Parse a binding value. Keyword matching is case-insensitive, but `exec`
    /// arguments preserve their original case (app names are case-sensitive).
    static func parse(_ raw: String) -> Action? {
        let tokens = raw.split(separator: " ").map(String.init)
        guard let head = tokens.first?.lowercased() else { return nil }
        let rest = Array(tokens.dropFirst())
        let lc = rest.map { $0.lowercased() }

        switch head {
        case "focus":
            if lc.first == "mode", lc.dropFirst().first == "toggle" { return .focusModeToggle }
            if let d = lc.first.flatMap(Direction.init(token:)) { return .focus(d) }
            return nil

        case "move":
            if let d = lc.first.flatMap(Direction.init(token:)) { return .move(d) }
            // i3 dialect: "move workspace N", "move to workspace N", "move container to workspace N".
            if lc.contains("workspace") || lc.contains("desktop"),
               let n = lc.compactMap({ Int($0) }).first { return .moveToWorkspace(n) }
            return nil

        case "workspace", "desktop":
            guard let n = lc.compactMap({ Int($0) }).first else { return nil }
            return .workspace(n)

        case "resize":
            guard let d = lc.first.flatMap(Direction.init(token:)) else { return nil }
            let amount = lc.count > 1 ? CGFloat(Double(lc[1]) ?? Double(defaultResizeStep)) : defaultResizeStep
            return .resize(d, amount)

        case "preselect", "split":
            if lc.first == "toggle" { return .toggleSplit }
            if let o = lc.first.flatMap(Orientation.init(token:)) { return .preselect(o) }
            return nil

        case "toggle":
            switch lc.first {
            case "split": return .toggleSplit
            case "float", "floating": return .toggleFloat
            default: return nil
            }

        case "balance": return .balance
        case "fullscreen", "zoom": return .fullscreen
        case "close", "kill": return .close

        case "exec":
            guard !rest.isEmpty else { return nil }
            return .exec(rest.joined(separator: " "))   // original case preserved

        case "reload": return .reload
        case "restart": return .restart

        case "mode":
            guard let name = lc.first else { return nil }
            return name == "default" ? .exitMode : .enterMode(name)

        case "dump":
            return .dumpTree

        default:
            return nil
        }
    }
}
