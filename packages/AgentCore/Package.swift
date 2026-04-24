// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "AnthropicProvider", targets: ["AnthropicProvider"]),
        .library(name: "OllamaProvider", targets: ["OllamaProvider"]),
        .library(name: "AgentOrchestrator", targets: ["AgentOrchestrator"]),
    ],
    dependencies: [
        .package(path: "../Keychain"),
        .package(path: "../Logging"),
        .package(path: "../Config"),
        .package(path: "../Replay"),
    ],
    targets: [
        // Core protocol surface — provider-agnostic.
        .target(
            name: "AgentCore",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "Config", package: "Config"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Anthropic Messages API provider — hand-rolled URLSession + SSE.
        .target(
            name: "AnthropicProvider",
            dependencies: [
                "AgentCore",
                .product(name: "Keychain", package: "Keychain"),
                .product(name: "JarvisLogging", package: "Logging"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Ollama provider — placeholder in Wave 1; filled in Plan 04-02.
        .target(
            name: "OllamaProvider",
            dependencies: [
                "AgentCore",
                .product(name: "JarvisLogging", package: "Logging"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Turn-lifecycle actor — Plan 04-04. Lives in its own target so it
        // can depend on Replay (which depends on AgentCore) without
        // introducing an SPM cycle. Plan 04-04's `files_modified` listed
        // these files under Sources/AgentCore/, but the literal layout
        // would have created Replay → AgentCore → Replay. Rule 3
        // deviation: split into AgentOrchestrator target.
        .target(
            name: "AgentOrchestrator",
            dependencies: [
                "AgentCore",
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "Config", package: "Config"),
                .product(name: "Replay", package: "Replay"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AnthropicProviderTests",
            dependencies: ["AnthropicProvider", "AgentCore"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OllamaProviderTests",
            dependencies: ["OllamaProvider", "AgentCore"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentOrchestratorTests",
            dependencies: [
                "AgentOrchestrator",
                "AgentCore",
                .product(name: "Config", package: "Config"),
                .product(name: "Replay", package: "Replay"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
