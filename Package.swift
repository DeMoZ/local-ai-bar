// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalAIBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        // App updates: "Проверить обновления", EdDSA-signed appcast published with each release.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalAIBar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LocalAIBar"
        )
    ]
)
