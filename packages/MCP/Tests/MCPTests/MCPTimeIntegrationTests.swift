// MCPTimeIntegrationTests.swift
//
// Round-trip acceptance for the `mcp-time` helper: register it via MCPClient,
// call `get_time`, parse the returned string with ISO8601DateFormatter and
// assert the date is within ±60 seconds of `Date()`.
//
// Resolution priority for the helper binary:
//   1. JARVIS_MCP_TIME_PATH env override (CI / local dev convenience).
//   2. The test bundle's own URL — when xcodebuild runs the tests, the test
//      bundle lives inside Jarvis.app/Contents/PlugIns/ and Contents/Helpers/
//      is two `..` away.
//   3. A walk up from #filePath looking for any built Jarvis.app under
//      Library/Developer/Xcode/DerivedData/* (DerivedData on macOS).
//   4. XCTSkip when none of the above resolves — `swift test --package-path
//      packages/MCP` standalone has no helper bundle, and that's expected.
//
// Plan: 05-02 / MCP-02.

import Foundation
import MCP
import XCTest
@testable import JarvisMCP

final class MCPTimeIntegrationTests: XCTestCase {

    func test_get_time_returns_iso8601() async throws {
        let binaryURL = try locateHelperBinary(
            envKey: "JARVIS_MCP_TIME_PATH",
            helperName: "mcp-time"
        )

        let client = MCPClient()
        try await client.register(
            name: "mcp-time",
            binaryURL: binaryURL,
            requiresConfirmation: false
        )

        // We must await shutdown() synchronously rather than via
        // `defer { Task { ... } }` — fire-and-forget shutdown leaks the
        // helper subprocess + its stdio pipe FDs into the next test, and
        // ChildSpawnGate's DEBUG `fatalError` precondition (FD must be
        // CLOEXEC) crashes the next spawn.
        do {
            let result = try await client.callTool(name: "get_time", arguments: [:])
            XCTAssertNotEqual(result.isError, true, "isError must not be true")
            XCTAssertEqual(result.content.count, 1)
            guard case let .text(text, _, _) = result.content.first else {
                XCTFail("expected .text content; got \(String(describing: result.content.first))")
                await client.shutdown()
                return
            }

            // Parse with the same formatOptions the helper uses (withInternetDateTime
            // + withFractionalSeconds). ISO8601DateFormatter accepts both with and
            // without fractional seconds when both options are set.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let parsed = formatter.date(from: text) else {
                XCTFail("returned text is not valid ISO 8601: \(text)")
                await client.shutdown()
                return
            }
            let delta = abs(parsed.timeIntervalSince(Date()))
            XCTAssertLessThan(delta, 60, "returned time \(parsed) is more than 60s away from now")
        }
        await client.shutdown()
    }
}
