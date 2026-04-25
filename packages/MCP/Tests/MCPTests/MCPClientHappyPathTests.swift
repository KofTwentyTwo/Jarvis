// MCPClientHappyPathTests.swift
//
// Spawn-side acceptance: register MockHelper, call mock_echo, verify the
// echoed text round-trips. Also covers spawn failure (binary missing) and
// the unregistered-name case.
//
// Plan: 05-01 Task 2 (MCP-01 + MCP-07 happy path)

import XCTest
import MCP
@testable import JarvisMCP

final class MCPClientHappyPathTests: XCTestCase {
    private var helperBinary: URL!

    override func setUp() async throws {
        try await super.setUp()
        helperBinary = try MockHelperBuilder.build()
    }

    func test_register_and_callTool_returnsEchoedText() async throws {
        let client = MCPClient()
        try await client.register(
            name: "mock-helper",
            binaryURL: helperBinary,
            requiresConfirmation: false
        )
        let result = try await client.callTool(
            name: "mock_echo",
            arguments: ["text": .string("hello-mcp-01")]
        )
        XCTAssertNotEqual(result.isError, true, "isError must not be true; got \(String(describing: result.isError))")
        XCTAssertEqual(result.content.count, 1)
        if case let .text(text, _, _) = result.content.first {
            XCTAssertEqual(text, "hello-mcp-01")
        } else {
            XCTFail("expected .text content; got \(String(describing: result.content.first))")
        }
        await client.shutdown()
    }

    func test_register_failsWith_spawnFailed_whenBinaryAbsent() async throws {
        let client = MCPClient()
        let bogus = URL(fileURLWithPath: "/usr/bin/this-binary-does-not-exist-jarvis-mcp")
        do {
            try await client.register(
                name: "missing-helper",
                binaryURL: bogus,
                requiresConfirmation: false
            )
            XCTFail("register should have thrown")
        } catch let JarvisMCPError.spawnFailed(name, _) {
            XCTAssertEqual(name, "missing-helper")
        } catch {
            XCTFail("expected JarvisMCPError.spawnFailed; got \(error)")
        }
        await client.shutdown()
    }

    func test_callTool_unregisteredName_throws_helperMissing() async throws {
        let client = MCPClient()
        do {
            _ = try await client.callTool(
                name: "tool_that_was_never_registered",
                arguments: [:]
            )
            XCTFail("callTool should have thrown")
        } catch let JarvisMCPError.helperMissing(name) {
            XCTAssertEqual(name, "tool_that_was_never_registered")
        } catch {
            XCTFail("expected JarvisMCPError.helperMissing; got \(error)")
        }
        await client.shutdown()
    }

    func test_toolMetadata_returnsServerName_andRequiresConfirmation() async throws {
        let client = MCPClient()
        try await client.register(
            name: "mock-helper",
            binaryURL: helperBinary,
            requiresConfirmation: true
        )
        let meta = await client.toolMetadata("mock_echo")
        XCTAssertEqual(meta?.name, "mock_echo")
        XCTAssertEqual(meta?.server, "mock-helper")
        XCTAssertEqual(meta?.requiresConfirmation, true)
        await client.shutdown()
    }

    /// WR-06 (REVIEW 05): callTool's `arguments` parameter is now
    /// optional matching the SDK signature. Calling without arguments
    /// must compile AND reach the helper (which then returns the
    /// "missing 'text' arg" isError because mock_echo requires text).
    /// What this proves: the optional-argument signature works without
    /// callers needing to pass `[:]`.
    func test_callTool_withoutArguments_isAccepted() async throws {
        let client = MCPClient()
        try await client.register(
            name: "mock-helper",
            binaryURL: helperBinary,
            requiresConfirmation: false
        )
        // No `arguments:` parameter at the call site — exercises the
        // default `nil` value WR-06 introduced.
        let result = try await client.callTool(name: "mock_echo")
        XCTAssertEqual(result.isError, true,
                       "mock_echo without text arg returns isError=true; the test asserts the call MAKES IT to the helper")
        await client.shutdown()
    }
}
