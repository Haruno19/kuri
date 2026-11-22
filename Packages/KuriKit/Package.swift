// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KuriKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KuriKit", targets: ["KuriCore", "KuriConfig", "KuriStore"]),
    ],
    targets: [
        .target(name: "KuriCore"),
        .target(name: "KuriConfig", dependencies: ["KuriCore"]),
        .target(name: "KuriStore", dependencies: ["KuriCore"]),

        .testTarget(name: "KuriCoreTests", dependencies: ["KuriCore"]),
        .testTarget(name: "KuriConfigTests", dependencies: ["KuriConfig"]),
        .testTarget(name: "KuriStoreTests", dependencies: ["KuriStore"]),
    ]
)
