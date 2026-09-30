// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeSwitcher",
            path: "Sources/ClaudeSwitcher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
