// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KuriKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KuriKit", targets: ["KuriCore"]),
    ],
    targets: [
        .target(name: "KuriCore"),
        .testTarget(name: "KuriCoreTests", dependencies: ["KuriCore"]),
    ]
)
