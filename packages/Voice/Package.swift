// swift-tools-version:6.0
// Phase 6 — Voice package.
//
// Package.swift is CLOSED for Phase 6: all three external dependencies are
// pinned here so Plans 06-02..06-05 never touch this file. Wave-2 plans
// (06-02 WakeWord + 06-03 VAD/STT) run in disjoint worktrees; their file
// ownership is limited to their own source subdirectories.
//
// Dep declarations carry NO source imports in this plan — those land in
// 06-02 (ORT for wake-word/VAD) and 06-04 (mlx-audio-swift for Orpheus).
// Resolution via `swift package resolve` is the v1 gate; import correctness
// is gated per plan.
import PackageDescription

let package = Package(
    name: "Voice",
    platforms: [.macOS(.v14)],  // ORT 1.24.2 requires macOS 14+
    products: [
        .library(name: "Voice", targets: ["Voice"]),
    ],
    dependencies: [
        // Pinned for Plans 06-02/06-03 (wake-word + VAD) — NOT imported here.
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            from: "1.24.2"
        ),
        // Pinned for Plan 06-03 (WhisperKit STT fallback) — NOT imported here.
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            from: "0.18.0"
        ),
        // Pinned for Plan 06-04 (Orpheus TTS tier 2) — NOT imported here.
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            from: "0.1.2"
        ),
    ],
    targets: [
        .target(
            name: "Voice",
            dependencies: [
                // Added by Plan 06-02 (WakeWord): ORT inference for mel/embedding/classifier.
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/Voice",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "VoiceTests",
            dependencies: ["Voice"],
            path: "Tests/VoiceTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
