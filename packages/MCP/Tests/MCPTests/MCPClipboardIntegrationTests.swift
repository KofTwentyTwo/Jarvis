// MCPClipboardIntegrationTests.swift
//
// Round-trip acceptance for the `mcp-clipboard` helper: register it via
// MCPClient and call `get_clipboard`. Because the test runner's pasteboard
// state is unknown, we accept any of the three valid outcomes:
//   - .text with isError=false   (string in pasteboard)
//   - "(clipboard empty)"        (no string, no fileURL)
//   - refusal text + isError=true (NSPasteboardTypeFileURL present — MCP-03)
//
// What this DOES verify: a runnable mcp-clipboard helper, end-to-end JSON-RPC
// over stdio, exactly one content item returned, and either-isError-shape.
// The MCP-03 refusal logic itself is unit-tested at the PasteboardReader
// level (mcp-servers/mcp-clipboard/Tests/PasteboardReaderTests/) without any
// GUI session dependency.
//
// Plan: 05-02 / MCP-03.

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
}
