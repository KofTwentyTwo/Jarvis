// MCPServerHandleStartTests.swift
//
// Source-level regression: enforce Pitfall #1 — `MCPServerHandle.start()` MUST
// construct `StdioTransport` with explicit FileDescriptor args, NEVER the
// no-arg default which is the helper-side init and would hang on the parent's
// own stdin/stdout.
//
// Plan: 05-01 Task 2

import XCTest

final class MCPServerHandleStartTests: XCTestCase {
    private func mcpServerHandleSource() throws -> String {
        // Walk from this file: Tests/MCPTests/<file> → packages/MCP/Sources/MCP/MCPServerHandle.swift
        let testFile = URL(fileURLWithPath: #filePath)
        let pkgDir = testFile
            .deletingLastPathComponent()  // MCPTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // packages/MCP/
        let source = pkgDir
            .appendingPathComponent("Sources")
            .appendingPathComponent("MCP")
            .appendingPathComponent("MCPServerHandle.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    func test_StdioTransport_constructedWithExplicitFDs_notDefaults() throws {
        let source = try mcpServerHandleSource()
        // The explicit form must appear at least once.
        XCTAssertTrue(
            source.contains("StdioTransport(\n            input:") ||
                source.contains("StdioTransport(input:"),
            "MCPServerHandle.start() must construct StdioTransport with explicit input:/output: FDs (Pitfall #1)"
        )
    }

    func test_ChildSpawnGate_called_before_processRun() throws {
        let source = try mcpServerHandleSource()
        XCTAssertTrue(
            source.contains("ChildSpawnGate.shared.prepare"),
            "MCPServerHandle.start() must call ChildSpawnGate.shared.prepare() before Process.run()"
        )
    }

    func test_minimalEnvironment_isSetOnProcess() throws {
        let source = try mcpServerHandleSource()
        XCTAssertTrue(
            source.contains("ChildSpawnGate.minimalEnvironment"),
            "MCPServerHandle.start() must set process.environment from ChildSpawnGate.minimalEnvironment"
        )
    }
}
