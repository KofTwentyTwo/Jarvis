// swift-tools-version:6.0
//
// Package: Vision
//
// Phase 7 / Plan 07-04 — webcam capture + presence detection (signal-only).
//
// VISION-03 architectural guard: this package MUST NOT depend on `Voice`
// (which carries the TTS engine) or on `AgentOrchestrator` (which carries
// `Orchestrator.runTurn`). The dependency-array below is the compile-time
// gate; scripts/check-vision-isolation.sh is the per-build textual gate
// (catches `import Voice` / `import AgentOrchestrator` regardless of SPM
// graph manipulation).
//
// AgentCore IS allowed because it carries the LLMProvider protocol and
// ImageBlock types that Plan 07-05 (frame-attach) consumes. Importing
// AgentCore does NOT pull AgentOrchestrator (separate target).
import PackageDescription

let package = Package(
    name: "Vision",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Vision", targets: ["Vision"]),
    ],
    dependencies: [
        .package(path: "../Logging"),
        .package(path: "../AgentCore"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Vision",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Vision",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VisionTests",
            dependencies: ["Vision"],
            path: "Tests/VisionTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
