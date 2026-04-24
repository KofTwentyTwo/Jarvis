// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Replay",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Replay", targets: ["Replay"]),
    ],
    dependencies: [
        .package(path: "../AgentCore"),
        .package(path: "../Logging"),
        .package(path: "../Config"),
    ],
    targets: [
        .target(
            name: "Replay",
            dependencies: [
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "Config", package: "Config"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ReplayTests",
            dependencies: ["Replay"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
