// ToolRegistryTests.swift
//
// Plan 05-04 Task 2 — tool→server lookup + requiresConfirmation flag.
// `ToolRegistry` is the value-type snapshot MCPToolDispatcher captures at
// init so its protocol-required `requiresConfirmation(toolName:)` can be
// `nonisolated` (sync read, no actor hop).

import XCTest
@testable import JarvisMCP

final class ToolRegistryTests: XCTestCase {

    func test_register_storesToolToServerMapping() {
        var registry = ToolRegistry()
        registry.register(toolName: "get_time", serverName: "mcp-time", requiresConfirmation: false)
        XCTAssertEqual(registry.server(forTool: "get_time"), "mcp-time")
    }

    func test_unknownTool_returnsNil() {
        let registry = ToolRegistry()
        XCTAssertNil(registry.server(forTool: "anything"))
        XCTAssertFalse(registry.requiresConfirmation(toolName: "anything"))
    }

    func test_requiresConfirmation_returnsCorrectFlag() {
        var registry = ToolRegistry()
        registry.register(toolName: "get_time", serverName: "mcp-time", requiresConfirmation: false)
        registry.register(toolName: "run_applescript", serverName: "mcp-applescript", requiresConfirmation: true)
        XCTAssertFalse(registry.requiresConfirmation(toolName: "get_time"))
        XCTAssertTrue(registry.requiresConfirmation(toolName: "run_applescript"))
    }

    func test_toolNames_listsAllRegistered() {
        var registry = ToolRegistry()
        registry.register(toolName: "get_time", serverName: "mcp-time", requiresConfirmation: false)
        registry.register(toolName: "get_clipboard", serverName: "mcp-clipboard", requiresConfirmation: false)
        registry.register(toolName: "run_applescript", serverName: "mcp-applescript", requiresConfirmation: true)
        XCTAssertEqual(registry.toolNames, ["get_clipboard", "get_time", "run_applescript"])
    }

    func test_register_overwritesExisting() {
        var registry = ToolRegistry()
        registry.register(toolName: "get_time", serverName: "mcp-time", requiresConfirmation: false)
        registry.register(toolName: "get_time", serverName: "mcp-time-v2", requiresConfirmation: true)
        XCTAssertEqual(registry.server(forTool: "get_time"), "mcp-time-v2")
        XCTAssertTrue(registry.requiresConfirmation(toolName: "get_time"))
    }
}
