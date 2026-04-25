// mcp-clipboard/main.swift
//
// MCP helper exposing a single `get_clipboard` tool. Reads NSPasteboard.general
// through a thin `SystemPasteboard` adapter that conforms to `PasteboardLike`,
// delegating refusal logic to `PasteboardReader`.
//
// Helpers MUST log to stderr only — stdout is the JSON-RPC stream. The SDK's
// default Logger writes to stderr; we deliberately avoid `print(...)` and
// avoid attaching custom log handlers that might write to stdout (Pitfall #4).
//
// Plan 05-02 / MCP-03.

import AppKit
import Foundation
import MCP

/// Production adapter: forwards `PasteboardLike` calls to `NSPasteboard.general`.
/// Pasteboard reads are synchronous on the calling thread — no `NSApplication.run()`
/// needed (RESEARCH Open Question #3 inverse).
///
/// `@unchecked Sendable`: `NSPasteboard` is not declared Sendable in AppKit,
/// but `NSPasteboard.general` is a process-wide singleton that AppKit
/// serializes internally for read access. The adapter holds no mutable state
/// of its own; capturing the singleton via `.general` inside each method also
/// avoids retaining a stale reference.
struct SystemPasteboard: PasteboardLike, @unchecked Sendable {
    var types: [NSPasteboard.PasteboardType]? { NSPasteboard.general.types }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        NSPasteboard.general.string(forType: type)
    }
}

@main
struct MCPClipboard {
    static func main() async throws {
        let server = Server(
            name: "mcp-clipboard",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "get_clipboard",
                    description: "Returns the current text content of the system clipboard. Refuses file URLs for security.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "get_clipboard" else {
                return CallTool.Result(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            let reader = PasteboardReader(pasteboard: SystemPasteboard())
            switch reader.read() {
            case .refusedFileURL:
                return CallTool.Result(
                    content: [.text(
                        text: "Clipboard contains a file URL; refusing to expose to model (MCP-03).",
                        annotations: nil,
                        _meta: nil
                    )],
                    isError: true
                )
            case .empty:
                return CallTool.Result(
                    content: [.text(text: "(clipboard empty)", annotations: nil, _meta: nil)],
                    isError: false
                )
            case .text(let s):
                return CallTool.Result(
                    content: [.text(text: s, annotations: nil, _meta: nil)],
                    isError: false
                )
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
