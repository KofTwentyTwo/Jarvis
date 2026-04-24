// swift-tools-version:6.0
import PackageDescription

// macOS 14 floor: @Observable (Observation framework) is macOS 14+. The rest
// of Phase 1 stays at macOS 13; DevOverlay is a developer-facing optional
// surface so raising its floor is acceptable.
let package = Package(
    name: "DevOverlay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DevOverlay", targets: ["DevOverlay"]),
    ],
    dependencies: [
        .package(path: "../AgentCore"),
        .package(path: "../Logging"),
    ],
    targets: [
        .target(
            name: "DevOverlay",
            dependencies: [
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "AgentOrchestrator", package: "AgentCore"),
                .product(name: "JarvisLogging", package: "Logging"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DevOverlayTests",
            dependencies: [
                "DevOverlay",
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "AgentOrchestrator", package: "AgentCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
