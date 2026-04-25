// mcp-time/main.swift
//
// MCP helper exposing a single `get_time` tool that returns the current
// local date/time as ISO 8601 (with fractional seconds + offset).
//
// Helpers MUST log to stderr only — stdout is the JSON-RPC stream. The SDK's
// default Logger writes to stderr; we deliberately avoid `print(...)` and
// avoid attaching custom log handlers that might write to stdout (Pitfall #4).
//
// Plan 05-02 / MCP-02.

import Foundation
import MCP

@main
struct MCPTime {
    static func main() async throws {
        let server = Server(
            name: "mcp-time",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "get_time",
                    description: "Returns the current local date and time as ISO 8601.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "get_time" else {
                return CallTool.Result(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso = formatter.string(from: Date())
            return CallTool.Result(
                content: [.text(text: iso, annotations: nil, _meta: nil)],
                isError: false
            )
        }

        // Default StdioTransport: reads from stdin, writes to stdout.
        // The parent (MCPClient) is the StdioTransport caveat (Pitfall #1);
        // helper side is fine with the default no-arg init.
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
