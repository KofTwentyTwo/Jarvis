// swift-tools-version:6.0
//
// Package: JarvisMCP
//
// IMPORTANT: We name the LIBRARY/TARGET `JarvisMCP` (not `MCP`) to avoid the
// name collision with the official `modelcontextprotocol/swift-sdk` library,
// which already exports a public library product named `MCP`. Mirrors the
// `JarvisLogging` pattern in `packages/Logging`. Source layout still lives
// under `Sources/MCP/` per the plan's file_modified paths.
//
// Plan: 05-01 (mcp-client-stdio-transport)

import PackageDescription

let package = Package(
    name: "JarvisMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "JarvisMCP", targets: ["JarvisMCP"]),
    ],
    dependencies: [
        // Pin SDK at exact 0.12.0 (no range float — pre-1.0 SDK).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
        .package(path: "../Logging"),
        // Plan 05-04: ASYMMETRIC dep on AgentCore (MCP→AgentCore only; never
        // the reverse). MCPToolDispatcher imports AgentCore for `ToolUseRequest`
        // and AgentOrchestrator for the `ToolDispatcher` protocol it conforms
        // to. AgentCore intentionally does NOT depend on MCP — the
        // orchestrator is provider-agnostic and only sees the protocol.
        .package(path: "../AgentCore"),
        // Plan 05-05 deviation (Rule 3, blocking): Sources `import
        // Logging` (swift-log) directly. SPM tolerated implicit
        // transitive visibility through JarvisLogging; the Xcode
        // framework linker is stricter and needs the explicit dep so
        // JarvisMCP.framework links cleanly when consumed by App target.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "JarvisMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "AgentOrchestrator", package: "AgentCore"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/MCP",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JarvisMCPTests",
            dependencies: ["JarvisMCP"],
            path: "Tests/MCPTests",
            // Exclude the MockHelper fixture sub-package from the test target so
            // SPM doesn't try to compile its `main.swift` as part of the test target.
            // The MockHelper is built separately at test setUp via `swift build`.
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
