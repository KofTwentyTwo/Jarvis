// HelperBundleLocator.swift
//
// Shared resolution logic for the round-trip integration tests against
// mcp-time and mcp-clipboard. Resolves the helper binary path or throws
// XCTSkip when no built bundle is reachable (e.g., when the package is
// tested via `swift test --package-path packages/MCP` without first
// running an Xcode build of the Jarvis scheme).
//
// Plan: 05-02 / Task 3.

import Foundation
import XCTest

/// Resolves a built helper binary path. Resolution order:
///   1. `envKey` env var (e.g., `JARVIS_MCP_TIME_PATH`) — full path override.
///   2. `Bundle.main.bundleURL` walk — when the test runner is hosted by
///      Jarvis.app, the helper bundle lives at `Contents/Helpers/<name>.app/
///      Contents/MacOS/<name>`. We probe both `Bundle.main` and the test's
///      own bundle.
///   3. DerivedData walk — `~/Library/Developer/Xcode/DerivedData/Jarvis-*/
///      Build/Products/{Debug,Release}/Jarvis.app/Contents/Helpers/<name>.app/
///      Contents/MacOS/<name>`.
///
/// Throws XCTSkip when none resolve.
func locateHelperBinary(envKey: String, helperName: String) throws -> URL {
    // 1. Env override
    if let path = ProcessInfo.processInfo.environment[envKey], !path.isEmpty {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }

    // 2. Bundle-based lookup. When run inside Jarvis.app the test bundle is
    // at Contents/PlugIns/<name>.xctest/. Walk up to find Contents/Helpers/.
    for bundle in [Bundle.main, Bundle(for: BundleProbe.self)] {
        let candidate = bundle.bundleURL
            .deletingLastPathComponent() // PlugIns or .app parent
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers")
            .appendingPathComponent("\(helperName).app")
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }

    // 3. DerivedData walk. Build a likely path under ~/Library/Developer/...
    //    Prefer Release over Debug: Xcode 26 Debug builds emit a
    //    `<helper>.debug.dylib` incremental-link artifact whose code signature
    //    diverges from the parent bundle's ad-hoc signing, causing dyld to
    //    reject the helper at process load with "different Team IDs" and the
    //    JSON-RPC handshake to time out. Release is statically linked so it
    //    runs as a standalone subprocess cleanly.
    let home = FileManager.default.homeDirectoryForCurrentUser
    let derivedRoot = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    if let entries = try? FileManager.default.contentsOfDirectory(
        at: derivedRoot,
        includingPropertiesForKeys: nil
    ) {
        for entry in entries where entry.lastPathComponent.hasPrefix("Jarvis-") {
            for config in ["Release", "Debug"] {
                let candidate = entry
                    .appendingPathComponent("Build/Products")
                    .appendingPathComponent(config)
                    .appendingPathComponent("Jarvis.app/Contents/Helpers")
                    .appendingPathComponent("\(helperName).app/Contents/MacOS")
                    .appendingPathComponent(helperName)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    // Defensive skip: Debug builds with an adjacent
                    // <helper>.debug.dylib will dyld-reject. Skip and try
                    // the next candidate (or fall through to XCTSkip).
                    let debugDylib = candidate
                        .deletingLastPathComponent()
                        .appendingPathComponent("\(helperName).debug.dylib")
                    if FileManager.default.fileExists(atPath: debugDylib.path) {
                        continue
                    }
                    return candidate
                }
            }
        }
    }

    throw XCTSkip("""
        \(helperName) helper bundle not found. Either:
          - Run `xcodebuild build -scheme Jarvis` first so DerivedData
            contains Jarvis.app/Contents/Helpers/\(helperName).app/, or
          - Set \(envKey)=/path/to/built/\(helperName) before invoking
            `swift test --package-path packages/MCP`.
        """)
}

/// Lightweight class used solely as a `Bundle(for:)` anchor for probing the
/// test bundle URL. Lives here (not in the test classes) so each integration
/// suite can share the same probe without re-declaring it.
private final class BundleProbe {}
