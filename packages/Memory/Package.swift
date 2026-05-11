// swift-tools-version:6.0
//
// Package: Memory
//
// Phase 7 / Plan 07-01 — local memory subsystem (SQLite + FTS5 + sqlite-vec).
//
// D-5/D-6 closure (2026-05-11): SQLite and sqlite-vec are now statically
// linked together via the `CSQLiteVec` target of jkrukowski/SQLiteVec.
// SQLiteConnection (in Replay) re-exports CSQLiteVec; Memory consumes it
// transitively but also names the product directly so the import in
// MemoryStore.swift resolves by name. The old runtime extension-loading
// pathway (sqlite3_load_extension via dlsym) is retired — it never worked
// on macOS because Apple strips that symbol from the system libsqlite3.
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
        // D-5/D-6: Memory directly imports CSQLiteVec for the
        // process-global `core_vec_init()` auto-extension registration.
        // Replay already pulls SQLiteVec for SQLiteConnection; declaring
        // here gives Memory a named product to import. Same version pin.
        .package(url: "https://github.com/jkrukowski/SQLiteVec.git", from: "0.0.14"),
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
                .product(name: "CSQLiteVec", package: "SQLiteVec"),
            ],
            path: "Sources/Memory",
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
