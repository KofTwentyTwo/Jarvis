// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "AnthropicProvider", targets: ["AnthropicProvider"]),
        .library(name: "OllamaProvider", targets: ["OllamaProvider"]),
    ],
    dependencies: [
        .package(path: "../Keychain"),
        .package(path: "../Logging"),
        .package(path: "../Config"),
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
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
