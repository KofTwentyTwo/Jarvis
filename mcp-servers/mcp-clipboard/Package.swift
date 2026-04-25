// swift-tools-version:6.0
//
// Package: mcp-clipboard
//
// MCP helper exposing a single `get_clipboard` tool. Refuses pasteboards that
// carry NSPasteboardTypeFileURL (MCP-03) regardless of accompanying string
// content — refusal precedes string extraction so a model can't coerce a
// path read by attaching a friendly-looking string to a fileURL pasteboard.
//
// Built and shipped as a separately-codesigned nested .app bundle under
// Jarvis.app/Contents/Helpers/mcp-clipboard.app/. Plan 05-02.

import PackageDescription

let package = Package(
    name: "mcp-clipboard",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "mcp-clipboard",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PasteboardReaderTests",
            dependencies: ["mcp-clipboard"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
