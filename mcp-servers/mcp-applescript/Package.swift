// swift-tools-version:6.0
//
// Package: mcp-applescript
//
// MCP helper exposing a single `run_applescript` tool that executes AppleScript
// source via in-process `NSAppleScript` (NEVER `Process()` shelling out to
// `/usr/bin/osascript` — RESEARCH Anti-Pattern: separate child has mixed TCC
// identity). Built and shipped as a separately-codesigned nested .app bundle
// under Jarvis.app/Contents/Helpers/mcp-applescript.app/.
//
// This is the ONLY helper that holds `com.apple.security.automation.apple-events`;
// scripts/verify-entitlements.sh enforces the bidirectional rule (this helper
// MUST carry it; no other helper may). Plan 05-03.
//
// The helper executes scripts unconditionally; the user-confirmation gate lives
// at the orchestrator boundary in Plan 05-05's ConfirmationBroker.

import PackageDescription

let package = Package(
    name: "mcp-applescript",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "mcp-applescript",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppleScriptRunnerTests",
            dependencies: ["mcp-applescript"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
