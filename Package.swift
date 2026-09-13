// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clipnotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clipnotch",
            path: "Sources/Clipnotch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
