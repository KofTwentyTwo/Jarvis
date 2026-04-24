import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

@MainActor
final class OrchestratorCapRecoveryTests: XCTestCase {
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
        provider mock: MockLLMProvider
    ) async throws -> (AgentOrchestrator, ReplayLog) {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "abc")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis"
        )
        return (orch, replay)
    }

    private func collectUntil(
        orch: AgentOrchestrator,
        timeout: TimeInterval = 5.0,
        predicate: @escaping (OrchestratorEvent) -> Bool
    ) async -> [OrchestratorEvent] {
        var collected: [OrchestratorEvent] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await event in orch.events {
            collected.append(event)
            if predicate(event) { return collected }
            if Date() > deadline { return collected }
        }
        return collected
    }

    /// Build a script set that exhausts the 10-tool-call budget (10 scripts
    /// each emitting 1 tool_use), followed by a final cap-recovery script
    /// that emits text + endTurn. Returns the matching MockLLMProvider.
    private func makeBudgetExhaustionScripts() -> MockLLMProvider {
        let toolReq = ToolUseRequest(id: "tu", name: "noop", argsJSON: Data("{}".utf8))
        var scripts: [MockLLMProvider.Script] = []
        for i in 0..<10 {
            scripts.append(.init(events: [
                .messageStart(LLMMessageStart(messageId: "iter\(i)", model: "x", usagePrefix: nil)),
                .toolUseRequested(toolReq),
                .stopReason(.toolUse),
                .messageStop,
            ]))
        }
        // 11th call — cap-recovery. tool_choice .none must reach this script.
        scripts.append(.init(events: [
            .messageStart(LLMMessageStart(messageId: "final", model: "x", usagePrefix: nil)),
            .textDelta("here is your answer"),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        return MockLLMProvider(scripts: scripts)
    }

    // MARK: - OC-Cap-1

    /// OC1 (cap-recovery): 10 tool_use calls in a row exhaust the budget; the
    /// 11th call uses toolChoice: .none.
    func test_capRecovery_OC1_budgetExhaustionTriggersToolChoiceNone() async throws {
        let mock = makeBudgetExhaustionScripts()
        let (orch, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("loop forever"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 11,
            "expected 10 tool-use calls + 1 cap-recovery = 11; got \(calls.count)")
    }

    // MARK: - OC-Cap-2 (AGENT-07 critical assertion)

    /// OC2 (cap-recovery, AGENT-07): the cap-recovery call's `toolChoice`
    /// equals `.none`.
    func test_capRecovery_OC2_recoveryCallToolChoiceIsNone() async throws {
        let mock = makeBudgetExhaustionScripts()
        let (orch, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("loop forever"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 11)
        XCTAssertEqual(calls[10].toolChoice, .none,
            "AGENT-07 critical: cap-recovery call MUST use toolChoice .none")
        XCTAssertTrue(calls[10].tools.isEmpty,
            "AGENT-07: cap-recovery must drop tools array entirely")
        // Spot-check earlier calls were `.auto`.
        XCTAssertEqual(calls[0].toolChoice, .auto)
        XCTAssertEqual(calls[5].toolChoice, .auto)
    }

    // MARK: - OC-Cap-3 (R4-L1 regression guard)

    /// OC3: the recovery call yields zero `.toolUseRequested` events. We
    /// can't assert what the model would have done in production, but our
    /// scripted recovery script does NOT emit a tool_use — confirming the
    /// orchestrator's behavior on a clean recovery path.
    func test_capRecovery_OC3_noToolUseOnRecoveryCall() async throws {
        let mock = makeBudgetExhaustionScripts()
        let (orch, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("loop forever"))
        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // Count toolCardUpdate.running events: should be exactly 10 (one per
        // tool-use loop iteration); if the recovery turn emitted an 11th
        // tool_use, this would be 11.
        let runningCount = events.compactMap { ev -> ToolCardUpdate? in
            if case .toolCardUpdate(let u) = ev, u.phase == .running { return u }
            return nil
        }.count
        XCTAssertEqual(runningCount, 10,
            "expected exactly 10 tool-running events; got \(runningCount)")
    }

    // MARK: - OC-Cap-4

    /// OC4: after cap-recovery, .turnEnd is emitted with the recovery turn's
    /// stop_reason (.endTurn for our scripted recovery).
    func test_capRecovery_OC4_turnEndAfterCapRecovery() async throws {
        let mock = makeBudgetExhaustionScripts()
        let (orch, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("loop forever"))
        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        XCTAssertTrue(events.contains(where: {
            if case .turnEnd(_, let r) = $0, r == .endTurn { return true }; return false
        }), "expected .turnEnd(.endTurn) after cap-recovery")
    }
}
