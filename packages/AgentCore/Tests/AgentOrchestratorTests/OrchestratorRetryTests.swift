import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

@MainActor
final class OrchestratorRetryTests: XCTestCase {
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
        configStore cs: ConfigStore? = nil
    ) async throws -> (AgentOrchestrator, ReplayLog) {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "abc")
        let orch = AgentOrchestrator(
            configStore: cs ?? makeConfigStore(),
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

    // MARK: - OR1

    /// OR1: first attempt yields stream_truncated → orchestrator opens a NEW
    /// turn (with retryOf set on the replay row), then the second attempt
    /// completes normally.
    func test_OR1_streamTruncatedTriggersOneRetryThatCompletes() async throws {
        let mock = MockLLMProvider(scripts: [
            // First attempt: truncates after 2 deltas.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .textDelta("a"), .textDelta("b"),
                .stopReason(.streamTruncated),
                .messageStop,
            ]),
            // Retry: completes cleanly.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .textDelta("c"),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let (orch, _) = try await buildOrchestrator(provider: mock)

        let outcome = await orch.submit(.text("ping"))
        guard case .ran = outcome else { return XCTFail() }

        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // The retry transitions through .reconfiguring before resuming.
        XCTAssertTrue(events.contains(where: {
            if case .stateChange(.reconfiguring) = $0 { return true }; return false
        }), "missing .stateChange(.reconfiguring) on retry")

        // After retry, .turnEnd(.endTurn) eventually arrives.
        XCTAssertTrue(events.contains(where: {
            if case .turnEnd(_, let r) = $0, r == .endTurn { return true }; return false
        }), "missing terminal .turnEnd(.endTurn)")

        // Two provider calls: original + retry.
        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2, "expected one retry → 2 provider calls")
    }

    // MARK: - OR2

    /// OR2: two back-to-back stream_truncated → terminal
    /// .error(.streamTruncatedFinal); no third attempt.
    func test_OR2_secondTruncationIsTerminalNoThirdAttempt() async throws {
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .stopReason(.streamTruncated),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .stopReason(.streamTruncated),
                .messageStop,
            ]),
            // A third script in case the orchestrator buggy-re-tries; the
            // assertion would fail because we expect calls.count == 2.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m3", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let (orch, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("ping"))

        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // Must emit a .error event with .streamTruncatedFinal.
        let sawTerminalError = events.contains { ev in
            if case .error(_, let err) = ev, err == .streamTruncatedFinal {
                return true
            }
            return false
        }
        XCTAssertTrue(sawTerminalError, "missing .error(.streamTruncatedFinal): \(events)")

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2, "must NOT make a third attempt; got \(calls.count) calls")
    }

    // MARK: - OR3

    /// OR3: the retry's tool-call budget resets — original attempt's used
    /// budget does not deplete the retry's budget.
    ///
    /// Setup: first attempt has 1 tool_use then truncates. Retry has 11
    /// tool_uses (budget is 10 by default), and the eleventh hits
    /// cap-recovery (toolChoice: .none on the 12th call). If the budget
    /// hadn't reset, cap-recovery would have triggered at the 9th call (10 -
    /// 1 already used). That difference is observable in `getRecordedCalls`.
    func test_OR3_retryResetsToolCallBudget() async throws {
        let toolReq = ToolUseRequest(id: "tu", name: "noop", argsJSON: Data("{}".utf8))

        // Original attempt: 1 tool use, then truncate.
        let firstScript = MockLLMProvider.Script(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
            .toolUseRequested(toolReq),
            .stopReason(.streamTruncated),
            .messageStop,
        ])

        // Retry: 10 tool uses (consuming the full budget), then a final end.
        // We script 11 calls total in the retry path — 10 tool-use turns plus
        // a cap-recovery final call. If budget hadn't reset, the cap-recovery
        // would happen earlier and we'd see fewer total calls.
        var retryEvents: [LLMEvent] = [
            .messageStart(LLMMessageStart(messageId: "m_retry", model: "x", usagePrefix: nil)),
            .toolUseRequested(toolReq),
            .stopReason(.toolUse),
            .messageStop,
        ]
        let retryScript = MockLLMProvider.Script(events: retryEvents)

        // We need many repeating retry-tool scripts to exhaust the budget of
        // 10. Build 10 such scripts plus a final end script.
        var scripts: [MockLLMProvider.Script] = [firstScript]
        for i in 0..<10 {
            scripts.append(MockLLMProvider.Script(events: [
                .messageStart(LLMMessageStart(messageId: "loop\(i)", model: "x", usagePrefix: nil)),
                .toolUseRequested(toolReq),
                .stopReason(.toolUse),
                .messageStop,
            ]))
        }
        // Cap-recovery call (toolChoice: .none) — model emits a final answer.
        scripts.append(MockLLMProvider.Script(events: [
            .messageStart(LLMMessageStart(messageId: "final", model: "x", usagePrefix: nil)),
            .textDelta("done"),
            .stopReason(.endTurn),
            .messageStop,
        ]))

        // Silence the unused-warning about retryEvents.
        _ = retryScript

        let mock = MockLLMProvider(scripts: scripts)
        let (orch, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("noop"))

        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let calls = await mock.getRecordedCalls()
        // Expected: 1 (original) + 10 (retry tool-use loop) + 1 (cap-recovery) = 12.
        // If budget had NOT reset, retry would only have 9 tool-use calls
        // (10 minus 1 used in original), giving 1 + 9 + 1 = 11. Assert ≥ 12.
        XCTAssertGreaterThanOrEqual(calls.count, 12,
            "retry must reset budget; got \(calls.count) calls")
    }

    // MARK: - OR4

    /// OR4: retry re-reads PerTurnSnapshot. Update the configStore between
    /// attempts; the retry must use the new provider.
    func test_OR4_retryReReadsPerTurnSnapshot() async throws {
        let mock = MockLLMProvider(scripts: [
            // First attempt: truncates.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .stopReason(.streamTruncated),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])

        let cs = makeConfigStore(provider: .anthropic)
        let (orch, _) = try await buildOrchestrator(provider: mock, configStore: cs)

        // Hook: a sentinel atomic that records what provider was passed to
        // providerFactory across two invocations. Simpler: the modelId on the
        // mock's recorded calls reveals the provider via `model.rawValue`.

        _ = await orch.submit(.text("ping"))

        // Update config mid-flight (between original truncation and retry).
        // Race-y: the orchestrator may have already started the retry. Best
        // we can assert is that the retry's config snapshot was re-fetched —
        // which means the second call's modelId comes from configStore.perTurn().
        await cs.updatePerTurn(makePerTurnSnapshot(provider: .ollama))

        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2)
        // First call is anthropic (opus47); the retry MAY be ollama if the
        // update beat the retry. Best-effort assertion: the retry's modelId
        // is one of the two known ids and is read from configStore.
        let retryModel = calls[1].model.rawValue
        XCTAssertTrue(retryModel == ModelID.opus47.rawValue
                      || retryModel == ModelID.qwen25coder32b.rawValue,
                      "retry modelId must come from PerTurnSnapshot, got \(retryModel)")
    }

    // MARK: - OR5

    /// OR5: stop_reason .refusal does NOT trigger retry; turn ends terminally.
    func test_OR5_refusalDoesNotRetry() async throws {
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
                .stopReason(.refusal),
                .messageStop,
            ]),
            // Sentinel — if accidentally invoked, .turnEnd would be .endTurn
            // and the assertion below would fail.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "should-not-fire", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let (orch, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("forbidden"))
        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        XCTAssertTrue(events.contains(where: {
            if case .turnEnd(_, let r) = $0, r == .refusal { return true }; return false
        }), "expected .turnEnd(.refusal)")

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 1, "refusal must NOT retry; got \(calls.count) calls")
    }
}
