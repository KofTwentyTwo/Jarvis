// ChildSpawnGateTests.swift
//
// Verifies the two invariants ChildSpawnGate enforces:
//   - minimalEnvironment is exactly {"PATH": "/usr/bin:/bin"}
//   - prepare() is non-throwing on the happy path (no leaked non-CLOEXEC FDs)
//   - a Process spawned with minimalEnvironment sees only PATH (no HOME, USER…)
//
// Plan: 05-01 (MCP-08)

import XCTest
@testable import JarvisChildSpawn

final class ChildSpawnGateTests: XCTestCase {
    func test_minimalEnvironment_isPathOnly() {
        let env = ChildSpawnGate.minimalEnvironment
        XCTAssertEqual(env.count, 1, "minimalEnvironment must have exactly one key")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
    }

    func test_prepare_succeedsOnHappyPath() async throws {
        // Calls the gate; on a well-instrumented Debug build, no FD should be
        // open above stderr without FD_CLOEXEC. If this fatalErrors in a future
        // change, the FD owner must be fixed — not this test.
        try await ChildSpawnGate.shared.prepare()
    }

    func test_spawnedChild_seesPathOnlyEnv() throws {
        // Launch /usr/bin/env with the minimal environment and assert stdout
        // is exactly "PATH=/usr/bin:/bin\n".
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = ChildSpawnGate.minimalEnvironment
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // A single line of exactly "PATH=/usr/bin:/bin"; no HOME=, USER=, TERM=, …
        XCTAssertEqual(
            output,
            "PATH=/usr/bin:/bin\n",
            "child must see exactly one env line; got:\n\(output)"
        )
        XCTAssertFalse(output.contains("HOME="))
        XCTAssertFalse(output.contains("USER="))
        XCTAssertFalse(output.contains("TERM="))
    }
}
