// MockHelperBuilder.swift
//
// Locates and lazily builds the MockHelper fixture executable used by the
// spawn-side tests in this package. The fixture lives at
// `Tests/MCPTests/Fixtures/MockHelper/` as its own SPM package; we shell out
// to `swift build -c release` once per test run and cache the binary URL.

import Foundation
import XCTest

enum MockHelperBuilder {
    /// Returns the file URL of the built MockHelper executable, building it
    /// (release configuration) on first call and returning the same path
    /// thereafter.
    static func build() throws -> URL {
        let fixtureDir = fixturePackageDir()
        let binary = fixtureDir
            .appendingPathComponent(".build")
            .appendingPathComponent("release")
            .appendingPathComponent("MockHelper")

        if FileManager.default.fileExists(atPath: binary.path) {
            return binary
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "-c", "release"]
        process.currentDirectoryURL = fixtureDir
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "MockHelperBuilder",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "swift build failed:\nstdout:\n\(stdoutText)\nstderr:\n\(stderrText)"]
            )
        }

        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw NSError(
                domain: "MockHelperBuilder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MockHelper binary not at expected path: \(binary.path)"]
            )
        }
        return binary
    }

    private static func fixturePackageDir() -> URL {
        // #filePath = packages/MCP/Tests/MCPTests/MockHelperBuilder.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MCPTests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MockHelper")
    }
}
