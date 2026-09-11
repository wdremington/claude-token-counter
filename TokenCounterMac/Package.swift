// swift-tools-version:6.0
import PackageDescription

// The test suite lives in the executable itself (`TokenCounter --test`) rather
// than in a testTarget: XCTest and swift-testing both ship with Xcode, and this
// package is built with Command Line Tools only.
let package = Package(
    name: "TokenCounter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TokenCounter",
            path: "Sources/TokenCounter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
