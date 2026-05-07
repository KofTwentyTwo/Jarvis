// InProcessAwareDispatchRoutingTests.swift
//
// Plan 10-02c (B-01b) — regression coverage for the dispatch routing bug.
//
// Bug: Plan 10-02b wired tool catalog ENUMERATION (model receives schemas
// for in-process tools) but missed dispatch ROUTING. When the model emitted
// a real `tool_use` for `get_active_audio_route`, the inner MCPToolDispatcher
// only knew about stdio tools (get_time/get_clipboard/run_applescript) and
// failed with "tool unknown", which the model surfaced as visible chat text.
//
// Fix: InProcessAwareToolDispatcher composite that name-routes to either
// the InProcessToolRegistry or the inner stdio dispatcher. Wraps the inner
// dispatcher; itself wrapped by ConfirmingToolDispatcher so confirmation
// gating, bus emission, and observer hooks fire identically on both paths.

import XCTest
import AgentCore
import AgentOrchestrator
@testable import JarvisMCP

// MARK: - Test fixtures

/// Canned in-process tool that records every call() and returns a fixed payload.
private actor CannedInProcessTool: InProcessTool {
    nonisolated let name: String
    nonisolated let toolDescription: String
    nonisolated let schemaJSON: Data
    nonisolated let requiresConfirmation: Bool
    private let payload: Data
    private(set) var callCount: Int = 0
    private(set) var lastArgs: Data?

    init(
        name: String,
        toolDescription: String = "canned tool",
        requiresConfirmation: Bool = false,
        payload: Data = Data("canned-payload".utf8),
        schemaJSON: Data = Data("{}".utf8)
    ) {
        self.name = name
        self.toolDescription = toolDescription
        self.requiresConfirmation = requiresConfirmation
        self.payload = payload
        self.schemaJSON = schemaJSON
    }

    func call(args: Data) async throws -> Data {
        callCount += 1
        lastArgs = args
        return payload
    }

    func snapshot() -> (count: Int, lastArgs: Data?) { (callCount, lastArgs) }
}

/// Stub inner ToolDispatcher (the stdio fallback). Records calls; returns canned bytes.
private actor StubInnerDispatcher: ToolDispatcher {
    struct Call: Equatable, Sendable { let id: String; let name: String }
    private(set) var calls: [Call] = []
    private let scriptedResult: Result<Data, Error>
    private let confirmationFor: [String: Bool]

    init(
        confirmationFor: [String: Bool] = [:],
        scriptedResult: Result<Data, Error> = .success(Data("stdio-result".utf8))
    ) {
        self.confirmationFor = confirmationFor
        self.scriptedResult = scriptedResult
    }

    func dispatch(toolUse: ToolUseRequest) async throws -> Data {
        calls.append(.init(id: toolUse.id, name: toolUse.name))
        switch scriptedResult {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }

    nonisolated func requiresConfirmation(toolName: String) -> Bool {
        confirmationFor[toolName] ?? false
    }

    func snapshot() -> [Call] { calls }
}

/// Recording observer (mirror of MCPToolDispatcherTests.RecordingObserver).
private actor RecordingObserver: ToolResultObserver {
    struct Record: Sendable, Equatable {
        let toolUseId: String
        let toolName: String
        let rawBytes: Data
        let sanitizedBytes: Data
    }
    private(set) var records: [Record] = []

    func record(toolUseId: String, toolName: String, rawBytes: Data, sanitizedBytes: Data) async {
        records.append(.init(
            toolUseId: toolUseId,
            toolName: toolName,
            rawBytes: rawBytes,
            sanitizedBytes: sanitizedBytes
        ))
    }
}

/// Bus spy for confirmation-gate test (mirrors ConfirmingToolDispatcherTests.SpyBus).
private actor SpyBus: BusGateway {
    enum Event: Sendable, Equatable {
        case start(id: String, name: String, preview: String)
        case update(id: String, name: String, preview: String)
        case end(id: String, name: String, ok: Bool, preview: String)
    }
    private(set) var events: [Event] = []

    func emitToolCallStart(toolUseId: String, name: String, argsPreview: String) async {
        events.append(.start(id: toolUseId, name: name, preview: argsPreview))
    }
    func updateArgsPreview(toolUseId: String, name: String, argsPreview: String) async {
        events.append(.update(id: toolUseId, name: name, preview: argsPreview))
    }
    func emitToolCallEnd(toolUseId: String, name: String, ok: Bool, previewOrError: String) async {
        events.append(.end(id: toolUseId, name: name, ok: ok, preview: previewOrError))
    }

    func snapshot() -> [Event] { events }
}

/// Scripted presenter (mirror of ConfirmingToolDispatcherTests.ScriptedPresenter).
private final class ScriptedPresenter: ConfirmationPresenting, @unchecked Sendable {
    private let outcome: ConfirmationOutcome
    private weak var broker: ConfirmationBroker?
    private let lock = NSLock()

    init(outcome: ConfirmationOutcome) { self.outcome = outcome }

    func setBroker(_ b: ConfirmationBroker) {
        lock.lock(); defer { lock.unlock() }
        self.broker = b
    }

    nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
        let outcome = self.outcome
        let broker = self.broker
        Task { await broker?.response(id: id, outcome: outcome) }
    }

    nonisolated func dismiss(id: UUID) async {}
}

// MARK: - Tests

final class InProcessAwareDispatchRoutingTests: XCTestCase {

    private func req(name: String, id: String = "tu-1", args: Data = Data()) -> ToolUseRequest {
        ToolUseRequest(id: id, name: name, argsJSON: args)
    }

    // MARK: 1. routes in-process tool to registry

    func test_routesInProcessToolToRegistry() async throws {
        let registry = InProcessToolRegistry()
        let canned = CannedInProcessTool(
            name: "canned_in_process_tool",
            payload: Data("from-in-process-registry".utf8)
        )
        await registry.register(canned)

        let inner = StubInnerDispatcher(
            scriptedResult: .success(Data("from-stdio-fallback".utf8))
        )

        let composite = InProcessAwareToolDispatcher(
            inProcessRegistry: registry,
            confirmationCache: registry.confirmationCache,
            inner: inner
        )

        let result = try await composite.dispatch(
            toolUse: req(name: "canned_in_process_tool")
        )

        // Sanitized payload (under 8 KB, ASCII, no zero-width chars) round-trips intact.
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "from-in-process-registry")

        let (count, _) = await canned.snapshot()
        XCTAssertEqual(count, 1, "in-process tool MUST be called exactly once")

        let stdioCalls = await inner.snapshot()
        XCTAssertTrue(stdioCalls.isEmpty, "stdio fallback MUST NOT be invoked for in-process tool")
    }

    // MARK: 2. routes unknown to inner stdio path

    func test_routesUnknownToInnerStdioPath() async throws {
        let registry = InProcessToolRegistry()  // EMPTY — every dispatch falls through.
        let inner = StubInnerDispatcher(
            scriptedResult: .success(Data("stdio-time-result".utf8))
        )

        let composite = InProcessAwareToolDispatcher(
            inProcessRegistry: registry,
            confirmationCache: registry.confirmationCache,
            inner: inner
        )

        let result = try await composite.dispatch(toolUse: req(name: "get_time"))
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "stdio-time-result")

        let stdioCalls = await inner.snapshot()
        XCTAssertEqual(stdioCalls, [.init(id: "tu-1", name: "get_time")])
    }

    // MARK: 3. confirmation gate preserved on in-process path

    func test_confirmationGatePreservedOnInProcessPath() async throws {
        // forget_fact-style tool: in-process AND requires confirmation.
        let registry = InProcessToolRegistry()
        let confirmTool = CannedInProcessTool(
            name: "fake_forget_fact",
            requiresConfirmation: true,
            payload: Data("forget-ack".utf8)
        )
        await registry.register(confirmTool)

        let inner = StubInnerDispatcher()  // never called
        let composite = InProcessAwareToolDispatcher(
            inProcessRegistry: registry,
            confirmationCache: registry.confirmationCache,
            inner: inner
        )

        // Composite reports confirmation required (sync read).
        XCTAssertTrue(composite.requiresConfirmation(toolName: "fake_forget_fact"),
                      "composite MUST surface in-process tool's requiresConfirmation:true")

        // Wrap with ConfirmingToolDispatcher (the production outer wrapper).
        let presenter = ScriptedPresenter(outcome: .approve)
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)
        presenter.setBroker(broker)
        let bus = SpyBus()
        let outer = ConfirmingToolDispatcher(
            inner: composite,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: { _ in "{}" }
        )

        let result = try await outer.dispatch(
            toolUse: req(name: "fake_forget_fact", id: "tu-confirm-1")
        )
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "forget-ack")

        // Bus saw the awaiting-approval seal.
        let events = await bus.snapshot()
        XCTAssertTrue(events.contains(where: {
            if case .start(_, let name, let preview) = $0 {
                return name == "fake_forget_fact" && preview == #"{"awaitingApproval":true}"#
            }
            return false
        }), "ConfirmingToolDispatcher MUST emit awaiting-approval seal even for in-process tools")

        // Tool was invoked exactly once (after broker approved).
        let (count, _) = await confirmTool.snapshot()
        XCTAssertEqual(count, 1)
    }

    // MARK: 4. tools registered AFTER dispatcher built are still routable

    func test_toolsRegisteredAfterDispatcherBuiltAreRoutable() async throws {
        let registry = InProcessToolRegistry()  // empty at construction.
        let inner = StubInnerDispatcher()
        let composite = InProcessAwareToolDispatcher(
            inProcessRegistry: registry,
            confirmationCache: registry.confirmationCache,
            inner: inner
        )

        // Register the tool LATER — simulating installSelfKnowledgeTools after MCPRuntime build.
        let lateTool = CannedInProcessTool(
            name: "late_registered_tool",
            payload: Data("late-payload".utf8)
        )
        await registry.register(lateTool)

        let result = try await composite.dispatch(toolUse: req(name: "late_registered_tool"))
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "late-payload")

        let (count, _) = await lateTool.snapshot()
        XCTAssertEqual(count, 1, "tool registered AFTER dispatcher init MUST still be routable")
    }

    // MARK: 5. observer fires on in-process path

    func test_inProcessResultFlowsThroughObserver() async throws {
        let registry = InProcessToolRegistry()
        let canned = CannedInProcessTool(
            name: "audited_tool",
            payload: Data("audited-result".utf8)
        )
        await registry.register(canned)

        let observer = RecordingObserver()
        let inner = StubInnerDispatcher()
        let composite = InProcessAwareToolDispatcher(
            inProcessRegistry: registry,
            confirmationCache: registry.confirmationCache,
            inner: inner,
            observer: observer
        )

        _ = try await composite.dispatch(
            toolUse: req(name: "audited_tool", id: "tu-audit", args: Data(#"{"k":"v"}"#.utf8))
        )

        let recs = await observer.records
        XCTAssertEqual(recs.count, 1, "observer MUST fire on in-process success path")
        XCTAssertEqual(recs.first?.toolName, "audited_tool")
        XCTAssertEqual(recs.first?.toolUseId, "tu-audit")
        XCTAssertEqual(String(decoding: recs.first?.rawBytes ?? Data(), as: UTF8.self), "audited-result")
        XCTAssertEqual(String(decoding: recs.first?.sanitizedBytes ?? Data(), as: UTF8.self), "audited-result")
    }
}
