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

// NOTE: The Swift module name is `JarvisVision` (not `Vision`) to avoid
// colliding with Apple's `Vision` framework — when a source file inside a
// module named `Vision` writes `import Vision`, Swift silently treats it
// as a self-import and skips loading Apple's framework, so Vision symbols
// (VNDetectFaceRectanglesRequest etc.) never resolve. Using `JarvisVision`
// matches the existing `JarvisLogging` convention. The package directory
// stays `packages/Vision` and the library product is `JarvisVision`;
// project.yml + scripts/check-vision-isolation.sh both key off the
// directory path.
let package = Package(
    name: "Vision",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisVision", targets: ["JarvisVision"]),
    ],
    dependencies: [
        .package(path: "../Logging"),
        .package(path: "../AgentCore"),
        // Plan 07-05 / Task 4: VllmMlxSidecar consumes ChildSpawnGate from
        // the standalone JarvisChildSpawn target inside the MCP package.
        // This is the ONLY MCP-package edge Vision pulls — JarvisChildSpawn
        // depends only on swift-log, so VISION-03 (no AgentOrchestrator,
        // no Voice transitively) still holds.
        .package(path: "../MCP"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "JarvisVision",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "OllamaProvider", package: "AgentCore"),
                .product(name: "AnthropicProvider", package: "AgentCore"),
                .product(name: "JarvisChildSpawn", package: "MCP"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Vision",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JarvisVisionTests",
            dependencies: [
                "JarvisVision",
                .product(name: "JarvisChildSpawn", package: "MCP"),
                .product(name: "AgentCore", package: "AgentCore"),
            ],
            path: "Tests/VisionTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
