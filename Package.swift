// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexReset",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CodexReset",
            path: "Sources/CodexReset"
        )
    ]
)
