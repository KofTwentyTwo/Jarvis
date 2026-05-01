// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Replay",
    // Plan 09-02 cascade — bumped from v13 to v14 because Replay's AgentCore
    // dependency now transitively pulls JarvisVision (macOS 14). Project
    // deployment target has always been macOS 14; v13 here was stale.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Replay", targets: ["Replay"]),
    ],
    dependencies: [
        .package(path: "../AgentCore"),
        .package(path: "../Logging"),
        .package(path: "../Config"),
        // Plan 05-05 deviation (Rule 3, blocking): Replay sources `import
        // Logging` (swift-log Logger) directly but the package never
        // declared swift-log as an explicit dep. SPM tolerated this via
        // transitive visibility through JarvisLogging; the Xcode
        // framework linker is stricter. Adding the explicit dep so
        // Replay.framework links cleanly when consumed by App target.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Replay",
            dependencies: [
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "Config", package: "Config"),
                .product(name: "Logging", package: "swift-log"),
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
