// swift-tools-version: 5.10
//
// jarvis-diag — programmatic test harness for the Jarvis API contract.
//
// This is the codified shape of the harness defined in
// `.planning/architecture/JARVIS-API-TEST-CONTRACT.md`. It is type-signatures-only
// at Phase 5; bodies are `fatalError("not implemented — IMPL: <scenario-id>")`.
// Implementation lands during the migration (M-0 .. M-7).
//
// Phase-5 status: skeleton compiles green using only the standard library + Foundation.
// Once `packages/JarvisAPI/` exists (M-0 step 1), uncomment the JarvisAPI dependency
// below and the surface accessors will return real surface types.

import PackageDescription

let package = Package(
    name: "jarvis-diag",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "JarvisDiag", targets: ["JarvisDiag"])
    ],
    dependencies: [
        // Uncomment after M-0 creates packages/JarvisAPI:
        // .package(path: "../../packages/JarvisAPI"),
        // .package(path: "../../packages/Bus"),
    ],
    targets: [
        .target(
            name: "JarvisDiag",
            dependencies: [
                // .product(name: "JarvisAPI", package: "JarvisAPI"),
                // .product(name: "Bus", package: "Bus"),
            ],
            path: "Sources/JarvisDiag"
        ),
        // Tests intentionally empty at Phase 5; scenarios are implemented during the migration.
        .testTarget(
            name: "JarvisDiagTests",
            dependencies: ["JarvisDiag"],
            path: "Tests/JarvisDiagTests"
        )
    ]
)
