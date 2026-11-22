// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KuriKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "KuriKit",
            targets: ["KuriCore", "KuriConfig", "KuriStore", "KuriInference", "KuriTools", "KuriMCP", "KuriAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "KuriCore"),
        .target(name: "KuriConfig", dependencies: ["KuriCore"]),
        .target(name: "KuriStore", dependencies: ["KuriCore"]),
        .target(name: "KuriInference", dependencies: ["KuriCore", "KuriConfig"]),
        .target(name: "KuriTools", dependencies: ["KuriCore", "KuriStore"]),
        .target(
            name: "KuriMCP",
            dependencies: [
                "KuriCore", "KuriConfig", "KuriTools",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .target(
            name: "KuriAgent",
            dependencies: ["KuriCore", "KuriConfig", "KuriStore", "KuriInference", "KuriTools", "KuriMCP"]),

        .testTarget(name: "KuriCoreTests", dependencies: ["KuriCore"]),
        .testTarget(name: "KuriConfigTests", dependencies: ["KuriConfig"]),
        .testTarget(name: "KuriStoreTests", dependencies: ["KuriStore"]),
        .testTarget(name: "KuriInferenceTests", dependencies: ["KuriInference", "KuriConfig"]),
        .testTarget(name: "KuriToolsTests", dependencies: ["KuriTools"]),
        .testTarget(
            name: "KuriMCPTests",
            dependencies: ["KuriMCP", "KuriTools", "KuriStore", "KuriConfig", .product(name: "MCP", package: "swift-sdk")],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "KuriAgentTests", dependencies: ["KuriAgent"]),
    ]
)
