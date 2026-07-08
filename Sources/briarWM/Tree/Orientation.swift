import CoreGraphics

/// How a split divides its space.
enum Orientation: String, Equatable, Codable {
    /// Children sit side-by-side; the split divides WIDTH (x-axis).
    case horizontal
    /// Children stack top/bottom; the split divides HEIGHT (y-axis).
    case vertical

    var flipped: Orientation { self == .horizontal ? .vertical : .horizontal }

    init?(token: String) {
        switch token.lowercased() {
        case "horizontal", "horiz", "h": self = .horizontal
        case "vertical", "vert", "v": self = .vertical
        default: return nil
        }
    }
}

/// A spatial direction used for focus / move / resize.
/// Note: all geometry is in AX top-left coordinates, so `up` means *smaller y*.
enum Direction: String, Equatable {
    case left, right, up, down

    /// The split axis this direction operates on.
    var orientation: Orientation {
        (self == .left || self == .right) ? .horizontal : .vertical
    }

    init?(token: String) {
        switch token.lowercased() {
        case "left", "west", "h": self = .left
        case "right", "east", "l": self = .right
        case "up", "north", "k": self = .up
        case "down", "south", "j": self = .down
        default: return nil
        }
    }
}
