// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Bus",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Bus", targets: ["Bus"]),
    ],
    dependencies: [
        .package(path: "../Logging"),
        // Plan 05-05 deviation (Rule 3, blocking): WebviewBridge imports
        // swift-log Logger directly. Same fix pattern as Replay /
        // AgentCore / MCP — Xcode framework linker is stricter than SPM.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Bus",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "BusTests",
            dependencies: ["Bus"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
