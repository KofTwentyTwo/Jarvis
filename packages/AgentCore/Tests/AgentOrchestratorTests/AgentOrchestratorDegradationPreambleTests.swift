import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// Round 4 — Slice 3 regression coverage. The Toby-the-dog incident
/// motivated this: when subsystems are degraded, the agent's system
/// prompt must include a "DO NOT promise" preamble so the model can't
/// confidently lie about a capability that's offline (memory off,
/// embedder missing, no API key).
///
/// The orchestrator exposes `setDegradationSummary(_:)` so AppDelegate
/// can update the summary after each boot-health re-probe. The first
/// turn after the setter call must thread the summary into the system
/// message at index 0.
@MainActor
final class AgentOrchestratorDegradationPreambleTests: XCTestCase {
    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    private func buildOrchestrator(
        provider mock: MockLLMProvider,
        initialSummary: String? = nil
    ) async throws -> (AgentOrchestrator, ReplayLog, SessionID) {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: [],
            degradationSummary: initialSummary
        )
        return (orch, replay, session)
    }

    private func collectUntilIdle(
        orch: AgentOrchestrator,
        timeout: TimeInterval = 5.0
    ) async -> [OrchestratorEvent] {
        var collected: [OrchestratorEvent] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await event in orch.events {
            collected.append(event)
            if case .stateChange(.idle) = event { return collected }
            if Date() > deadline { return collected }
        }
        return collected
    }

    /// Extracts the first system-message's concatenated text content.
    private func systemText(_ msg: LLMMessage) -> String {
        var out = ""
        for block in msg.content {
            if case let .text(s) = block { out += s }
        }
        return out
    }

    // MARK: - DP-1

    /// DP-1: orchestrator constructed with a `degradationSummary` must
    /// prepend it BEFORE the system prompt on the first turn. The model
    /// sees the warning at the very top of the system message.
    func test_DP1_initialSummaryThreadedIntoFirstTurnSystemPrompt() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let summary = """
        CRITICAL — SUBSYSTEMS DEGRADED:
        - memory: failed (vec0 missing) — DO NOT promise to use memory
        - ollama: degraded — missing models: nomic-embed-text
        Be honest. Do not claim to use tools that are unavailable. Do not pretend memory works if it doesn't.
        """
        let (orch, _, _) = try await buildOrchestrator(provider: mock, initialSummary: summary)

        let outcome = await orch.submit(.text("remember my dog Toby is a golden retriever"))
        guard case .ran = outcome else { return XCTFail("expected .ran, got \(outcome)") }

        _ = await collectUntilIdle(orch: orch)

        let recorded = await mock.getRecordedCalls()
        XCTAssertEqual(recorded.count, 1)
        guard let firstSystem = recorded[0].messages.first, firstSystem.role == .system else {
            return XCTFail("first message must be .system")
        }
        let text = systemText(firstSystem)
        XCTAssertTrue(
            text.contains("CRITICAL — SUBSYSTEMS DEGRADED"),
            "system prompt must contain the degradation header"
        )
        XCTAssertTrue(
            text.contains("DO NOT promise to use memory"),
            "system prompt must contain the 'DO NOT promise' string for the failed subsystem"
        )
        XCTAssertTrue(
            text.contains("Do not pretend memory works if it doesn't"),
            "system prompt must contain the canonical honesty directive"
        )
        // Degradation must appear BEFORE the base system prompt ("you are jarvis").
        if let degRange = text.range(of: "CRITICAL — SUBSYSTEMS DEGRADED"),
           let baseRange = text.range(of: "you are jarvis") {
            XCTAssertTrue(
                degRange.lowerBound < baseRange.lowerBound,
                "degradation summary must be prepended before the base system prompt"
            )
        } else {
            XCTFail("expected both degradation header and base prompt in system message")
        }
    }

    // MARK: - DP-2

    /// DP-2: a nil/empty summary must produce a system prompt
    /// indistinguishable from the pre-Round-4 behavior — no leftover
    /// "CRITICAL —" tag, no extra newlines.
    func test_DP2_nilSummaryLeavesSystemPromptUnchanged() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let (orch, _, _) = try await buildOrchestrator(provider: mock, initialSummary: nil)

        let outcome = await orch.submit(.text("hi"))
        guard case .ran = outcome else { return XCTFail("expected .ran") }
        _ = await collectUntilIdle(orch: orch)

        let recorded = await mock.getRecordedCalls()
        let text = systemText(recorded[0].messages[0])
        XCTAssertFalse(
            text.contains("CRITICAL"),
            "no summary → no 'CRITICAL' marker in system prompt"
        )
        XCTAssertFalse(
            text.contains("DO NOT promise"),
            "no summary → no 'DO NOT promise' directive in system prompt"
        )
    }

    // MARK: - DP-3

    /// DP-3: `setDegradationSummary` updates the orchestrator's view so
    /// the NEXT turn's system prompt reflects the new summary. This is
    /// the boot-order critical path: installAgent runs BEFORE runBootHealth,
    /// so the orchestrator is constructed with `nil` and the summary is
    /// pushed in post-construction.
    func test_DP3_setDegradationSummaryAppliesToNextTurn() async throws {
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "claude-opus-4-7", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let (orch, _, _) = try await buildOrchestrator(provider: mock, initialSummary: nil)

        // Turn 1 — no summary set yet.
        let outcome1 = await orch.submit(.text("hi"))
        guard case .ran = outcome1 else { return XCTFail("expected .ran") }
        _ = await collectUntilIdle(orch: orch)

        // Set summary AFTER turn 1; turn 2 should pick it up.
        await orch.setDegradationSummary("CRITICAL — SUBSYSTEMS DEGRADED:\n- memory: vec0 missing")

        let outcome2 = await orch.submit(.text("remember Toby"))
        guard case .ran = outcome2 else { return XCTFail("expected .ran") }
        _ = await collectUntilIdle(orch: orch)

        let recorded = await mock.getRecordedCalls()
        XCTAssertEqual(recorded.count, 2)
        let turn1System = systemText(recorded[0].messages[0])
        let turn2System = systemText(recorded[1].messages[0])

        XCTAssertFalse(turn1System.contains("CRITICAL"), "turn 1 (pre-set) must have no degradation marker")
        XCTAssertTrue(turn2System.contains("CRITICAL"), "turn 2 (post-set) must include the degradation marker")
        XCTAssertTrue(turn2System.contains("vec0 missing"), "turn 2 system prompt must echo the new reason")
    }

    // MARK: - DP-4

    /// DP-4: clearing the summary (passing `nil` after a previous set)
    /// removes it from the next turn — used when a re-probe finds every
    /// subsystem returned to `.ok`.
    func test_DP4_clearingSummaryRestoresPlainPrompt() async throws {
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "claude-opus-4-7", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let (orch, _, _) = try await buildOrchestrator(provider: mock, initialSummary: "CRITICAL — SUBSYSTEMS DEGRADED:\n- memory: vec0 missing")

        // Turn 1 — summary live.
        _ = await orch.submit(.text("hi"))
        _ = await collectUntilIdle(orch: orch)

        // Clear summary.
        await orch.setDegradationSummary(nil)

        _ = await orch.submit(.text("hello again"))
        _ = await collectUntilIdle(orch: orch)

        let recorded = await mock.getRecordedCalls()
        let turn1System = systemText(recorded[0].messages[0])
        let turn2System = systemText(recorded[1].messages[0])
        XCTAssertTrue(turn1System.contains("CRITICAL"))
        XCTAssertFalse(turn2System.contains("CRITICAL"), "cleared summary must not leak into the next turn")
    }
}
