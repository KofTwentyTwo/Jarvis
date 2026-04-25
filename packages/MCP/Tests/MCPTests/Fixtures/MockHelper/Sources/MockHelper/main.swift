// MockHelper/main.swift
//
// Test fixture: a minimal MCP helper that exposes two tools:
//   - mock_echo(text: String) -> echoes the input
//   - mock_slow(ms: Int = 1500) -> sleeps then echoes (used by restart tests)
//
// Optional environment knobs (test-only):
//   MOCK_HELPER_CRASH_AFTER=N  → exit(137) after N successful tool calls
//   MOCK_HELPER_TALLY_PATH=…   → append a single line "started\n" at startup
//                                 (used to count restart cycles)
//
// Helpers MUST log to stderr only — stdout is the JSON-RPC stream. The SDK's
// default StdioTransport reads from stdin and writes to stdout; loggers go
// through Swift Logging which defaults to stderr.

import Foundation
import MCP

@main
struct MockHelper {
    static func main() async throws {
        // Side-channel: append a marker on every fresh start so restart-cycle
        // tests can verify the helper was actually re-launched.
        if let tallyPath = ProcessInfo.processInfo.environment["MOCK_HELPER_TALLY_PATH"] {
            if let fh = FileHandle(forWritingAtPath: tallyPath) {
                _ = try? fh.seekToEnd()
                _ = try? fh.write(contentsOf: Data("started\n".utf8))
                _ = try? fh.close()
            } else {
                // File didn't exist — create with this initial line.
                _ = try? Data("started\n".utf8).write(to: URL(fileURLWithPath: tallyPath))
            }
        }

        // Track call count locally for the optional crash-after-N behavior.
        // We use a shared mutable box because the SDK's CallTool handler is
        // an `@Sendable` closure; a simple reference type captured by the
        // closure handles the mutation across calls cleanly.
        let callTracker = CallTracker(
            crashAfter: ProcessInfo.processInfo.environment["MOCK_HELPER_CRASH_AFTER"]
                .flatMap(Int.init)
        )

        let server = Server(
            name: "mock-helper",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            return ListTools.Result(tools: [
                Tool(
                    name: "mock_echo",
                    description: "Echo input text.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("text")])
                    ])
                ),
                Tool(
                    name: "mock_slow",
                    description: "Sleep, then echo input text. Used by restart tests.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object(["type": .string("string")]),
                            "ms": .object(["type": .string("integer")])
                        ]),
                        "required": .array([.string("text")])
                    ])
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            let count = callTracker.increment()
            if let n = callTracker.crashAfter, count > n {
                // Force-crash: matches the SIGKILL-from-parent path used by
                // restart tests. exit(137) ≈ SIGKILL exit semantics.
                exit(137)
            }
            switch params.name {
            case "mock_echo":
                guard let text = params.arguments?["text"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "missing 'text' arg", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                return CallTool.Result(
                    content: [.text(text: text, annotations: nil, _meta: nil)],
                    isError: false
                )
            case "mock_slow":
                let ms = params.arguments?["ms"]?.intValue ?? 1500
                let text = params.arguments?["text"]?.stringValue ?? "slow"
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                return CallTool.Result(
                    content: [.text(text: text, annotations: nil, _meta: nil)],
                    isError: false
                )
            default:
                return CallTool.Result(
                    content: [.text(text: "unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        // Default StdioTransport: reads from stdin, writes to stdout.
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}

/// Reference-type call counter shared across SDK's @Sendable handler closures.
/// Synchronized via NSLock — the SDK may dispatch handlers concurrently, and
/// even if it didn't today, contracting on serial dispatch here is fragile.
final class CallTracker: @unchecked Sendable {
    let crashAfter: Int?
    private var count: Int = 0
    private let lock = NSLock()

    init(crashAfter: Int?) {
        self.crashAfter = crashAfter
    }

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}
