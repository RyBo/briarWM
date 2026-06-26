// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "briarWM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "briarWM", targets: ["briarWM"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "briarWM",
            dependencies: [
                "Yams",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/briarWM"
        ),
        .testTarget(
            name: "briarWMTests",
            dependencies: ["briarWM"],
            path: "Tests/briarWMTests"
        ),
    ],
    // This app is single-threaded on the main run loop and uses C callbacks /
    // global state that Swift 6 strict concurrency would reject, so build the
    // code in Swift 5 language mode.
    swiftLanguageModes: [.v5]
)
