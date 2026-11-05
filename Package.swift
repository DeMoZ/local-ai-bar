// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalAIBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LocalAIBar", path: "Sources/LocalAIBar")
    ]
)
