import Testing
@testable import briarWM

@Suite struct OrientationTests {

    @Test(arguments: [
        ("horizontal", Orientation.horizontal),
        ("horiz", .horizontal),
        ("h", .horizontal),
        ("HORIZONTAL", .horizontal),   // case-insensitive
        ("vertical", .vertical),
        ("vert", .vertical),
        ("v", .vertical),
        ("Vert", .vertical),
    ])
    func orientationTokens(token: String, expected: Orientation) {
        #expect(Orientation(token: token) == expected)
    }

    @Test func orientationRejectsUnknown() {
        #expect(Orientation(token: "diagonal") == nil)
    }

    @Test(arguments: [
        ("left", Direction.left),
        ("west", .left),
        ("h", .left),
        ("right", .right),
        ("east", .right),
        ("l", .right),
        ("up", .up),
        ("north", .up),
        ("k", .up),
        ("down", .down),
        ("south", .down),
        ("j", .down),
        ("EAST", .right),              // case-insensitive
    ])
    func directionTokens(token: String, expected: Direction) {
        #expect(Direction(token: token) == expected)
    }

    @Test func directionRejectsUnknown() {
        #expect(Direction(token: "inward") == nil)
    }
}
