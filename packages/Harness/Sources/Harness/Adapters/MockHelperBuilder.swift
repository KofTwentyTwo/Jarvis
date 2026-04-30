import Foundation

/// Locates and lazily builds the MockHelper fixture executable used by the
/// MCP spawn-side tests. Lifted verbatim (with a path-resolution adjustment)
/// from `packages/MCP/Tests/MCPTests/MockHelperBuilder.swift` per
/// `.planning/phases/08-hardening/08-03-live-and-integration-runners-PLAN.md`
/// Task 2 — the MCP test target's builder is private to that target, but
/// `MCPCrashRunner` (a Harness library type) needs the same fixture
/// to drive 50–100 register/crash/restart cycles via real `MCPClient`
/// calls.
///
/// The fixture itself is unchanged — same SPM package under
/// `packages/MCP/Tests/MCPTests/Fixtures/MockHelper/`. Only the path-
/// resolution from the source file's location changes.
public enum HarnessMockHelperBuilder {
    public enum BuildError: Swift.Error {
        case swiftBuildFailed(stdout: String, stderr: String, status: Int32)
        case binaryMissing(path: String)
        case fixtureNotFound(path: String)
    }

    /// Returns the file URL of the built MockHelper executable, building
    /// it (release configuration) on first call and returning the same
    /// path thereafter.
    public static func build() throws -> URL {
        let fixtureDir = try fixturePackageDir()
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
            throw BuildError.swiftBuildFailed(
                stdout: stdoutText,
                stderr: stderrText,
                status: process.terminationStatus
            )
        }
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BuildError.binaryMissing(path: binary.path)
        }
        return binary
    }

    /// Resolves the MockHelper fixture directory from this source file's
    /// location: walk up from `packages/Harness/Sources/Harness/Adapters/`
    /// to repo root, then descend into the MCP test fixtures path.
    private static func fixturePackageDir() throws -> URL {
        // #filePath = packages/Harness/Sources/Harness/Adapters/MockHelperBuilder.swift
        // We want    packages/MCP/Tests/MCPTests/Fixtures/MockHelper/
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()  // Adapters/
            .deletingLastPathComponent()  // Harness/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // Harness/  (package dir)
            .deletingLastPathComponent()  // packages/
        let fixture = repoRoot
            .appendingPathComponent("packages")
            .appendingPathComponent("MCP")
            .appendingPathComponent("Tests")
            .appendingPathComponent("MCPTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MockHelper")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw BuildError.fixtureNotFound(path: fixture.path)
        }
        return fixture
    }
}
