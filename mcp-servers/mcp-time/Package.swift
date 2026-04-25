// swift-tools-version:6.0
//
// Package: mcp-time
//
// MCP helper exposing a single `get_time` tool returning the current local
// date/time as ISO 8601. Built and shipped as a separately-codesigned nested
// .app bundle under Jarvis.app/Contents/Helpers/mcp-time.app/.
//
// Standalone SPM package (peer of `packages/`) so `swift build` works without
// xcodegen + Xcode for fast iteration. Plan 05-02.

import PackageDescription

let package = Package(
    name: "mcp-time",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "mcp-time",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
