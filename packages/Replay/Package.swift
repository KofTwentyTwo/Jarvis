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
        // D-5/D-6 closure (2026-05-11): retire the hand-rolled extension-
        // loading dlsym pathway. jkrukowski/SQLiteVec ships `CSQLiteVec`
        // which compiles sqlite3.c + sqlite-vec.c + an `extinit.c` glue
        // (`core_vec_init` → `sqlite3_auto_extension(sqlite3_vec_init)`)
        // into one static-linked C target. SQLiteConnection imports
        // CSQLiteVec instead of the SDK's `SQLite3.tbd`, so all our
        // `sqlite3_*` calls resolve to a SQLite that has vec0 built in.
        // Apple's stripping of `sqlite3_load_extension` is irrelevant —
        // no runtime extension loading is needed. License: MIT.
        .package(url: "https://github.com/jkrukowski/SQLiteVec.git", from: "0.0.14"),
    ],
    targets: [
        .target(
            name: "Replay",
            dependencies: [
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "Config", package: "Config"),
                .product(name: "Logging", package: "swift-log"),
                // D-5/D-6: SQLite + vec0 statically linked together.
                // Replay's SQLiteConnection.swift imports CSQLiteVec instead of
                // SQLite3, so every consumer of Replay (Memory, App target)
                // automatically uses the vec0-bundled sqlite3 build.
                .product(name: "CSQLiteVec", package: "SQLiteVec"),
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
