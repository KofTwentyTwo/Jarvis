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
///
/// WR-05 (REVIEW 05): pasteboard reads now hop to MainActor via
/// `MainActor.assumeIsolated` (or `MainActor.run` from non-MainActor
/// contexts). macOS Sequoia/Sonoma have been progressively requiring
/// main-thread access for NSPasteboard.general reads in some
/// configurations; reads from background threads can return stale or
/// empty data with no error. The integration test
/// `test_get_clipboard_seeded_returnsSeededString_CR04` (CR-04 fix-pass)
/// asserts a real round-trip, so a regression here would surface as a
/// test failure rather than the silent-empty mode the original code had.
///
/// `@unchecked Sendable`: `NSPasteboard` is not declared Sendable in
/// AppKit, but `NSPasteboard.general` is a process-wide singleton.
struct SystemPasteboard: PasteboardLike, @unchecked Sendable {
    var types: [NSPasteboard.PasteboardType]? {
        // Synchronous MainActor hop. The PasteboardLike protocol's
        // `types` property is non-async; on a non-Main caller we need a
        // blocking trampoline. dispatchPrecondition + DispatchQueue.main.sync
        // is the standard idiom; assumeIsolated avoids the dispatch
        // overhead on the fast path.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { NSPasteboard.general.types }
        }
        return DispatchQueue.main.sync { NSPasteboard.general.types }
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { NSPasteboard.general.string(forType: type) }
        }
        return DispatchQueue.main.sync { NSPasteboard.general.string(forType: type) }
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
