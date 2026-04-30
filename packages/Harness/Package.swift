// swift-tools-version:6.0
//
// Package: Harness
//
// Phase 8 — eval matrix + replay-roundtrip oracle. Library target for reusable
// test plumbing (Oracle, Runners, Adapters, FDLeakDetector); executable target
// `jarvis-eval` exposes the eight pillars as swift-argument-parser
// subcommands. Tests-of-the-harness in Tests/HarnessTests/.
//
// Plan 08-01 substrate: Harness library exposes ExclusionList / DriftReport /
// DriftClassifier / ReplayMCPAdapter / MockLLMProvider / ReplayRunner. Later
// plans (08-02..08-04) add corpus runners and the remaining pillars.
//
// Platform floor `.macOS(.v14)` matches Voice (ORT 1.24.2 floor) for
// downstream integration; Memory's `.macOS(.v13)` is a relaxation we don't
// need here.
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
        .executable(name: "jarvis-eval", targets: ["jarvis-eval"]),
    ],
    dependencies: [
        .package(path: "../Logging"),
        .package(path: "../Config"),
        .package(path: "../AgentCore"),
        .package(path: "../Replay"),
        .package(path: "../MCP"),
        .package(path: "../Voice"),
        .package(path: "../Memory"),
        .package(path: "../DevOverlay"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Plan 08-03 Task 2: MCPCrashRunner uses real MCPClient.callTool
        // which takes `[String: Value]?` arguments (Value lives in the
        // swift-sdk's MCP product, distinct from our local JarvisMCP
        // library). This dep is consumed only by MCPCrashRunner.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
    ],
    targets: [
        .target(
            name: "Harness",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "Config", package: "Config"),
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "AgentOrchestrator", package: "AgentCore"),
                .product(name: "AnthropicProvider", package: "AgentCore"),
                .product(name: "OllamaProvider", package: "AgentCore"),
                .product(name: "Replay", package: "Replay"),
                .product(name: "JarvisMCP", package: "MCP"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Voice", package: "Voice"),
                .product(name: "Memory", package: "Memory"),
                .product(name: "DevOverlay", package: "DevOverlay"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Harness",
            resources: [
                .copy("../../Corpora"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "jarvis-eval",
            dependencies: [
                "Harness",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/jarvis-eval",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["Harness"],
            path: "Tests/HarnessTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
