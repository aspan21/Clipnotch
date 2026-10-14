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
        ),
        // Run by Claude Code hooks: forwards each event to the app's socket.
        // Foundation only, so it starts in milliseconds on every tool call.
        .executableTarget(
            name: "clipnotch-hook",
            path: "Sources/ClipnotchHook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
