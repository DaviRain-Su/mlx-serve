// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MLXCore",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to 0.11.0: 0.12.0 uses Swift 6.2-only `withThrowingTaskGroup { ... }` which
        // breaks the build on macos-14's Xcode (Swift 6.1.x). 0.12 added OAuth flows we don't use.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", "0.11.0" ..< "0.12.0"),
        // Already pulled transitively by swift-sdk; declared here so we can use OrderedDictionary
        // directly to preserve user-edited key order in mcp.json.
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MLXCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            path: "Sources/MLXServe",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "MLXCoreTests",
            dependencies: ["MLXCore"],
            path: "Tests/MLXCoreTests"
        ),
    ]
)
