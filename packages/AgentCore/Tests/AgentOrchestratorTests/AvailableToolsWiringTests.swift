import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// Plan 10-02b / B-01 regression. The 2026-05-07 live-launch verification
/// surfaced that `App/AppDelegate.swift:1274` constructed
/// `AgentOrchestrator(... availableTools: [], ...)` with a hardcoded empty
/// array, silencing every tool call across the agent (including the four
/// Phase 10-01 self-knowledge tools, the Phase 7 memory tools, and the
/// Phase 5 stdio helper tools). The model saw the system-prompt preamble
/// naming tools but had no schemas in the API `tools[]` array, so it
/// hallucinated JSON tool definitions into chat instead of dispatching
/// real `tool_use` blocks.
///
/// This regression test asserts at the orchestrator → provider boundary:
/// when `AgentOrchestrator` is constructed with a non-empty
/// `availableTools:` list, the `LLMProvider.stream(...)` call MUST receive
/// that same list of `ToolSchema`s in its `tools:` argument. The previous
/// in-process registry test (`registersFourSelfKnowledgeTools`) asserted
/// at the wrong layer — the registry was correctly populated, but its
/// catalog never reached the orchestrator constructor. This test catches
/// the substrate gap.
@MainActor
final class AvailableToolsWiringTests: XCTestCase {
    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    /// B-01-REGRESSION: passing N schemas to `availableTools:` MUST result
    /// in the same N schemas reaching the provider's `stream(... tools:)`
    /// call on the first turn.
    func test_availableToolsReachProviderFirstCall() async throws {
        // Arrange: build an orchestrator with three tool schemas mirroring
        // the production catalog shape — name, description, and a JSON
        // Schema bytes blob.
        let schemas: [ToolSchema] = [
            ToolSchema(
                name: "get_active_audio_route",
                description: "Returns the active mic + speaker route.",
                inputSchema: Data(#"{"type":"object","properties":{}}"#.utf8)
            ),
            ToolSchema(
                name: "list_audio_devices",
                description: "Lists audio I/O devices on the host.",
                inputSchema: Data(#"{"type":"object","properties":{}}"#.utf8)
            ),
            ToolSchema(
                name: "get_self_state",
                description: "Returns the runtime self-state snapshot.",
                inputSchema: Data(#"{"type":"object","properties":{}}"#.utf8)
            ),
        ]

        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "claude-opus-4-7", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: schemas
        )

        // Act: submit a turn so the orchestrator opens a stream.
        let outcome = await orch.submit(.text("hello"))
        guard case .ran = outcome else {
            return XCTFail("expected .ran, got \(outcome)")
        }

        // Drain to .idle so the provider's recorded calls are stable.
        for await event in orch.events {
            if case .stateChange(.idle) = event { break }
        }

        // Assert: the provider received exactly the schemas we passed.
        let recorded = await mock.getRecordedCalls()
        XCTAssertGreaterThanOrEqual(recorded.count, 1, "provider was never called")
        let firstTools = recorded[0].tools
        XCTAssertEqual(firstTools.count, schemas.count,
                       "B-01: orchestrator's first stream() call carried \(firstTools.count) tools, expected \(schemas.count)")
        XCTAssertEqual(Set(firstTools.map(\.name)), Set(schemas.map(\.name)),
                       "B-01: tool names reaching the provider differ from the input catalog")
    }

    /// B-01-NEGATIVE: explicitly verifies that a default-init (omitting
    /// `availableTools:`) yields an empty `tools:` array at the provider.
    /// This pins down the precondition that the BUG was about hardcoding
    /// `[]` at a CONSTRUCTION site, not about a default-arg behavior
    /// change.
    func test_defaultAvailableToolsYieldsEmptyToolsAtProvider() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "claude-opus-4-7", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis"
            // availableTools omitted → defaults to [].
        )
        _ = await orch.submit(.text("hello"))
        for await event in orch.events {
            if case .stateChange(.idle) = event { break }
        }
        let recorded = await mock.getRecordedCalls()
        XCTAssertGreaterThanOrEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].tools.isEmpty,
                      "default-init must yield empty tools (the bug is in the construction site, not the default)")
    }
}
