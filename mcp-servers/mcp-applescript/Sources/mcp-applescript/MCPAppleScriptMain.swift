// mcp-applescript/MCPAppleScriptMain.swift
//
// MCP helper exposing a single `run_applescript` tool that executes
// AppleScript source via in-process `NSAppleScript`. We deliberately do NOT
// shell out to a subprocess to run scripts — that would split the TCC
// identity from this helper bundle and defeat the per-helper trust
// isolation that the entitlement layout enforces. See AppleScriptRunner.swift
// for the rejection rationale (T-05-03-03).
//
// Helpers MUST log to stderr only — stdout is the JSON-RPC stream. The SDK's
// default Logger writes to stderr; we deliberately avoid `print(...)` and
// avoid attaching custom log handlers that might write to stdout (Pitfall #4).
//
// At init the helper runs a trivial scaffold-time probe that exercises
// `NSAppleScript` and writes the outcome to stderr (RESEARCH Open Question #3:
// does NSAppleScript work without `NSApp.run()`?). If the probe hangs or
// returns -600, a future plan wraps the helper in NSApplicationDelegate +
// NSApp.run().
//
// File renamed from `main.swift` → `MCPAppleScriptMain.swift` to allow
// `@main` on a struct (Xcode rejects @main in a file named main.swift).
// Plan 05-03.

import Foundation
import MCP

@main
struct MCPAppleScript {
    static func main() async throws {
        let runner: any AppleScriptRunning = NSAppleScriptRunner()

        // Scaffold-time probe (RESEARCH Open Question #3 + T-05-03-05).
        // Runs a trivial script that does not require event-loop pumping
        // and writes the outcome to stderr ONLY (Pitfall #4 — never stdout).
        // If this hangs in production, future plans wrap the helper in
        // NSApplicationDelegate + NSApp.run().
        let probeOutcome = runner.run(
            source: "tell application \"System Events\" to get the name of every process"
        )
        FileHandle.standardError.write(
            Data("mcp-applescript probe outcome: \(probeOutcome)\n".utf8)
        )

        let server = Server(
            name: "mcp-applescript",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "run_applescript",
                    description: "Executes AppleScript source. Requires user confirmation (gated by host).",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "source": .object([
                                "type": .string("string"),
                                "description": .string("AppleScript source code to execute.")
                            ])
                        ]),
                        "required": .array([.string("source")])
                    ])
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "run_applescript" else {
                return CallTool.Result(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            guard let source = params.arguments?["source"]?.stringValue else {
                return CallTool.Result(
                    content: [.text(text: "Missing 'source' argument.", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            switch runner.run(source: source) {
            case .success(let text):
                return CallTool.Result(
                    content: [.text(text: text, annotations: nil, _meta: nil)],
                    isError: false
                )
            case .runtimeError(let number, let message):
                return CallTool.Result(
                    content: [.text(text: "AppleScript error \(number): \(message)", annotations: nil, _meta: nil)],
                    isError: true
                )
            case .compileFailure:
                return CallTool.Result(
                    content: [.text(text: "AppleScript source failed to compile.", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
