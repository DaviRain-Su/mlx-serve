// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MLXClaw",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MLXClaw",
            path: "Sources/MLXServe",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "MLXClawTests",
            path: "Tests/MLXClawTests"
        ),
    ]
)
