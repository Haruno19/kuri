// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KuriKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "KuriKit",
            targets: ["KuriCore", "KuriConfig", "KuriStore", "KuriInference", "KuriTools", "KuriAgent"]),
    ],
    targets: [
        .target(name: "KuriCore"),
        .target(name: "KuriConfig", dependencies: ["KuriCore"]),
        .target(name: "KuriStore", dependencies: ["KuriCore"]),
        .target(name: "KuriInference", dependencies: ["KuriCore", "KuriConfig"]),
        .target(name: "KuriTools", dependencies: ["KuriCore", "KuriStore"]),
        .target(
            name: "KuriAgent",
            dependencies: ["KuriCore", "KuriConfig", "KuriStore", "KuriInference", "KuriTools"]),

        .testTarget(name: "KuriCoreTests", dependencies: ["KuriCore"]),
        .testTarget(name: "KuriConfigTests", dependencies: ["KuriConfig"]),
        .testTarget(name: "KuriStoreTests", dependencies: ["KuriStore"]),
        .testTarget(name: "KuriInferenceTests", dependencies: ["KuriInference"]),
        .testTarget(name: "KuriToolsTests", dependencies: ["KuriTools"]),
        .testTarget(name: "KuriAgentTests", dependencies: ["KuriAgent"]),
    ]
)
