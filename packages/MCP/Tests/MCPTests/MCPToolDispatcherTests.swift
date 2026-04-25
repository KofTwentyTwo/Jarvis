// MCPToolDispatcherTests.swift
//
// Plan 05-04 Task 3 — `MCPToolDispatcher` conforms to AgentOrchestrator's
// `ToolDispatcher` protocol. Tests cover:
//
//   - happy-path text concatenation + sanitize
//   - multi-block .text concatenation
//   - under-cap passthrough vs over-cap truncation marker
//   - error propagation from the underlying client
//   - synchronous requiresConfirmation read
//   - ToolResultObserver receives both pre- and post-sanitize bytes
//   - observer NOT called on error (no post-sanitize bytes to record)
//
// Tests use a mock `MCPClientCalling` conformer rather than spawning a
// subprocess — the boundary contract under test is "client returned text
// → dispatcher sanitizes + returns Data". Subprocess wiring is covered by
// MCPClientHappyPathTests + helper-integration tests in 05-01..05-03.

import XCTest
import MCP
import AgentCore
import AgentOrchestrator
@testable import JarvisMCP

// MARK: - Mock client

/// Minimal `MCPClientCalling` conformer for unit tests. Does not spawn,
/// does not implement the SDK transport layer; just returns whatever the
/// caller wires up via `nextResult` / `nextError`.
private actor MockClient: MCPClientCalling {
    enum Mode {
        case ok([Tool.Content])
        case error(Error)
    }
    var mode: Mode = .ok([.text(text: "", annotations: nil, _meta: nil)])
    var lastCallName: String?
    var lastCallArguments: [String: Value]?
    var callCount: Int = 0

    func setMode(_ m: Mode) { self.mode = m }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        lastCallName = name
        lastCallArguments = arguments
        callCount += 1
        switch mode {
        case .ok(let content):
            return CallTool.Result(content: content, isError: false)
        case .error(let err):
            throw err
        }
    }
}

// MARK: - Recording observer

/// Captures every observer callback so tests can assert before/after bytes.
private actor RecordingObserver: ToolResultObserver {
    struct Record: Sendable {
        let toolUseId: String
        let toolName: String
        let rawBytes: Data
        let sanitizedBytes: Data
    }
    private(set) var records: [Record] = []

    func record(toolUseId: String, toolName: String, rawBytes: Data, sanitizedBytes: Data) async {
        records.append(Record(
            toolUseId: toolUseId,
            toolName: toolName,
            rawBytes: rawBytes,
            sanitizedBytes: sanitizedBytes
        ))
    }
}

// MARK: - Tests

final class MCPToolDispatcherTests: XCTestCase {

    private func makeRegistry() -> ToolRegistry {
        var r = ToolRegistry()
        r.register(toolName: "get_time", serverName: "mcp-time", requiresConfirmation: false)
        r.register(toolName: "get_clipboard", serverName: "mcp-clipboard", requiresConfirmation: false)
        r.register(toolName: "run_applescript", serverName: "mcp-applescript", requiresConfirmation: true)
        return r
    }

    private func req(name: String, id: String = "tu1", argsJSON: Data = Data()) -> ToolUseRequest {
        ToolUseRequest(id: id, name: name, argsJSON: argsJSON)
    }

    // MARK: - dispatch happy path: sanitize fires

    func test_dispatch_callsClientThenSanitizes() async throws {
        let mock = MockClient()
        await mock.setMode(.ok([.text(text: "hello\u{200B}\u{202E}world", annotations: nil, _meta: nil)]))

        let dispatcher = MCPToolDispatcher(client: mock, registry: makeRegistry())
        let bytes = try await dispatcher.dispatch(toolUse: req(name: "get_time"))
        let str = String(decoding: bytes, as: UTF8.self)

        // Zero-width + bidi stripped; no truncation marker; no wrap envelope.
        XCTAssertEqual(str, "helloworld")
    }

    // MARK: - dispatch happy path: multiple .text blocks join

    func test_dispatch_concatenatesMultipleTextContent() async throws {
        let mock = MockClient()
        await mock.setMode(.ok([
            .text(text: "first", annotations: nil, _meta: nil),
            .text(text: "second", annotations: nil, _meta: nil),
        ]))

        let dispatcher = MCPToolDispatcher(client: mock, registry: makeRegistry())
        let bytes = try await dispatcher.dispatch(toolUse: req(name: "get_time"))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "first\nsecond")
    }

    // MARK: - dispatch: cap behaviors

    func test_dispatch_underTruncationCap_doesNotTruncate() async throws {
        let mock = MockClient()
        // 100 chars, plain ASCII, well under 8192.
        let small = String(repeating: "a", count: 100)
        await mock.setMode(.ok([.text(text: small, annotations: nil, _meta: nil)]))

        let dispatcher = MCPToolDispatcher(client: mock, registry: makeRegistry())
        let bytes = try await dispatcher.dispatch(toolUse: req(name: "get_time"))
        let out = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(out, small)
        XCTAssertFalse(out.contains("…[tool-result-truncated"))
    }

    func test_dispatch_overTruncationCap_addsMarker() async throws {
        let mock = MockClient()
        // 20000 chars on a single line: per-line cap (4096) hits FIRST and
        // produces ~4096 + line-truncated marker; that's well under the 8192
        // boundary cap, so no boundary marker. Use a multi-line input to
        // exceed the boundary cap meaningfully.
        let line = String(repeating: "a", count: 4000) // under per-line cap
        let blob = Array(repeating: line, count: 5).joined(separator: "\n")
        // ~20004 bytes total → over 8192.
        XCTAssertGreaterThan(blob.utf8.count, 8192)
        await mock.setMode(.ok([.text(text: blob, annotations: nil, _meta: nil)]))

        let dispatcher = MCPToolDispatcher(client: mock, registry: makeRegistry())
        let bytes = try await dispatcher.dispatch(toolUse: req(name: "get_time"))
        let out = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(
            out.hasSuffix("…[tool-result-truncated at 8192 bytes]"),
            "expected boundary truncation marker; got suffix \(out.suffix(60))"
        )
    }

    // MARK: - error propagation

    func test_dispatch_propagatesMCPError() async throws {
        let mock = MockClient()
        await mock.setMode(.error(JarvisMCPError.serverCrashed(name: "mcp-time")))

        let dispatcher = MCPToolDispatcher(client: mock, registry: makeRegistry())
        do {
            _ = try await dispatcher.dispatch(toolUse: req(name: "get_time"))
            XCTFail("expected error to propagate")
        } catch let JarvisMCPError.serverCrashed(name) {
            XCTAssertEqual(name, "mcp-time")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - synchronous requiresConfirmation

    func test_requiresConfirmation_readsRegistry_synchronously() async throws {
        let mock = MockClient()
        let dispatcher = MCPToolDispatcher(client: mock, registry: makeRegistry())

        // These calls are SYNCHRONOUS (no await) — the protocol declares them
        // as sync. Backed by the value-type registry snapshot.
        XCTAssertTrue(dispatcher.requiresConfirmation(toolName: "run_applescript"))
        XCTAssertFalse(dispatcher.requiresConfirmation(toolName: "get_time"))
        XCTAssertFalse(dispatcher.requiresConfirmation(toolName: "unknown_tool"))
    }

    // MARK: - observer pre/post bytes

    func test_observer_receivesPreAndPostSanitizeBytes() async throws {
        let mock = MockClient()
        await mock.setMode(.ok([.text(text: "x\u{200B}y", annotations: nil, _meta: nil)]))

        let observer = RecordingObserver()
        let dispatcher = MCPToolDispatcher(
            client: mock,
            registry: makeRegistry(),
            observer: observer
        )
        _ = try await dispatcher.dispatch(toolUse: req(name: "get_time", id: "tu-obs"))

        let records = await observer.records
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.toolUseId, "tu-obs")
        XCTAssertEqual(r.toolName, "get_time")
        XCTAssertEqual(String(decoding: r.rawBytes, as: UTF8.self), "x\u{200B}y")
        XCTAssertEqual(String(decoding: r.sanitizedBytes, as: UTF8.self), "xy")
    }

    func test_observer_isNotCalled_onError() async throws {
        let mock = MockClient()
        await mock.setMode(.error(JarvisMCPError.serverCrashed(name: "mcp-time")))

        let observer = RecordingObserver()
        let dispatcher = MCPToolDispatcher(
            client: mock,
            registry: makeRegistry(),
            observer: observer
        )

        do {
            _ = try await dispatcher.dispatch(toolUse: req(name: "get_time"))
            XCTFail("expected error")
        } catch {
            // expected
        }

        let records = await observer.records
        XCTAssertEqual(records.count, 0, "observer must not be invoked when client throws")
    }
}
