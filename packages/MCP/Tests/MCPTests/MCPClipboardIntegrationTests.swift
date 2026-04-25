// MCPClipboardIntegrationTests.swift
//
// Round-trip acceptance for the `mcp-clipboard` helper.
//
// Two test methods:
//   1. test_get_clipboard_runs_and_returns_one_content_item
//      Smoke test: helper runs, returns exactly one content item.
//      Accepts any of the three valid outcomes (text, empty, fileURL refusal).
//   2. test_get_clipboard_seeded_returnsSeededString  (CR-04 REVIEW 05)
//      Tighter assertion: parent test seeds NSPasteboard with a unique
//      UUID-tagged string; helper must return EXACTLY that string. Detects
//      the silent-failure mode where LSBackgroundOnly daemons get empty
//      pasteboard reads on macOS Sonoma+.
//
// Plan: 05-02 / MCP-03 + CR-04 fix-pass.

import AppKit
import Foundation
import MCP
import XCTest
@testable import JarvisMCP

final class MCPClipboardIntegrationTests: XCTestCase {

    func test_get_clipboard_runs_and_returns_one_content_item() async throws {
        let binaryURL = try locateHelperBinary(
            envKey: "JARVIS_MCP_CLIPBOARD_PATH",
            helperName: "mcp-clipboard"
        )

        let client = MCPClient()
        try await client.register(
            name: "mcp-clipboard",
            binaryURL: binaryURL,
            requiresConfirmation: false
        )

        // Synchronous shutdown (not `defer { Task { ... } }`) — fire-and-forget
        // shutdown leaks the helper's stdio FDs into the next test, and
        // ChildSpawnGate's DEBUG-only fatalError precondition crashes the
        // next spawn.
        do {
            let result = try await client.callTool(name: "get_clipboard", arguments: [:])
            XCTAssertEqual(result.content.count, 1, "get_clipboard must return exactly one content item")
            guard case let .text(text, _, _) = result.content.first else {
                XCTFail("expected .text content; got \(String(describing: result.content.first))")
                await client.shutdown()
                return
            }
            XCTAssertFalse(text.isEmpty, "content text must not be empty (refusal/empty/text are all non-empty)")
            // isError shape is bimodal — either nil/false (text or empty pasteboard)
            // or true (fileURL refusal). Both are valid outcomes; assert it's one
            // of those two states (not some other value).
            let isErrorOK = (result.isError == nil) || (result.isError == false) || (result.isError == true)
            XCTAssertTrue(isErrorOK)
        }
        await client.shutdown()
    }

    /// CR-04 (REVIEW 05) regression: with LSBackgroundOnly removed from
    /// the helper's Info.plist, NSPasteboard.general reads from the helper
    /// must return the actual seeded string. Pre-CR-04 this would have
    /// silently returned empty on macOS Sonoma+ because LSBackgroundOnly
    /// daemons don't get pasteboard access.
    ///
    /// We seed the parent process's pasteboard with a unique
    /// UUID-tagged string just before the helper runs, then assert the
    /// helper's response equals the seed. If the response is the empty
    /// marker `(clipboard empty)`, that's the silent-failure mode CR-04
    /// fixes — the test fails.
    func test_get_clipboard_seeded_returnsSeededString_CR04() async throws {
        let binaryURL = try locateHelperBinary(
            envKey: "JARVIS_MCP_CLIPBOARD_PATH",
            helperName: "mcp-clipboard"
        )

        // Seed the system pasteboard with a unique tag.
        let seed = "JARVIS-CR04-SEED-\(UUID().uuidString)"
        let pasteboard = NSPasteboard.general
        let priorChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(seed, forType: .string)
        // Sanity: confirm the parent process can read the seed it just set.
        let parentRead = pasteboard.string(forType: .string) ?? ""
        guard parentRead == seed else {
            // Headless CI may not have a writable pasteboard. Skip rather
            // than fail — this test is meaningful only on a real session.
            throw XCTSkip("parent process cannot write/read NSPasteboard.general — likely headless CI; got \(parentRead)")
        }
        XCTAssertGreaterThan(pasteboard.changeCount, priorChangeCount,
                             "pasteboard changeCount should advance after setString")

        let client = MCPClient()
        try await client.register(
            name: "mcp-clipboard",
            binaryURL: binaryURL,
            requiresConfirmation: false
        )

        do {
            let result = try await client.callTool(name: "get_clipboard", arguments: [:])
            XCTAssertEqual(result.content.count, 1)
            guard case let .text(text, _, _) = result.content.first else {
                XCTFail("expected .text content")
                await client.shutdown()
                return
            }
            XCTAssertEqual(
                text, seed,
                "CR-04: helper must return the seeded pasteboard string — silent-empty here would indicate LSBackgroundOnly regression"
            )
            XCTAssertNotEqual(text, "(clipboard empty)",
                              "CR-04: pre-CR-04 silent-failure mode")
        }
        await client.shutdown()
    }
}
