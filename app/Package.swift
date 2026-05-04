// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MLXCore",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to 0.10.x — last version without Swift 6.2-only `withThrowingTaskGroup { ... }`
        // syntax. macos-14's Xcode is Swift 6.1.x. 0.11 added 2025-11-25 spec coverage + icons +
        // elicitation updates we don't use; 0.12 added OAuth we don't use.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", "0.10.2" ..< "0.11.0"),
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
