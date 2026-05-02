// swift-tools-version:6.0
//
// Package: Memory
//
// Phase 7 / Plan 07-01 — local memory subsystem (SQLite + FTS5 + sqlite-vec).
//
// Memory has NO external SPM dependencies. sqlite-vec v0.1.10-alpha.3 is
// loaded as a runtime dylib via direct sqlite3_load_extension C API; it is
// NOT a Swift package. System libsqlite3 is pulled in via "import SQLite3"
// from Foundation — see packages/Replay/Sources/Replay/SQLiteConnection.swift
// line 2 for the same idiom.
//
// SQLiteConnection is reused from Replay (its docstring lines 12-22 explicitly
// says it was authored with Phase 7 in mind). Plan 07-01 adds a withHandle(_:)
// accessor to SQLiteConnection so Memory can call sqlite3_load_extension.
import PackageDescription

let package = Package(
    name: "Memory",
    // Plan 09-02 cascade — bumped from v13 to v14 because Memory depends on
    // AgentCore (now v14 due to JarvisVision dependency in AgentOrchestrator's
    // vision-dispatch path).
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Memory", targets: ["Memory"]),
    ],
    dependencies: [
        .package(path: "../Logging"),
        .package(path: "../AgentCore"),
        .package(path: "../Replay"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Memory",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "AgentOrchestrator", package: "AgentCore"),
                .product(name: "Replay", package: "Replay"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Memory",
            resources: [
                .copy("Resources/PLACEHOLDER.txt"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemoryTests",
            dependencies: [
                "Memory",
                // Plan 07-06: MemoryRegressionCorpusTests drives MemoryExtractor
                // end-to-end against a real local Ollama under JARVIS_REAL_MODELS=1.
                // The OllamaProvider product is the live LLMProvider implementation.
                .product(name: "OllamaProvider", package: "AgentCore"),
            ],
            path: "Tests/MemoryTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
