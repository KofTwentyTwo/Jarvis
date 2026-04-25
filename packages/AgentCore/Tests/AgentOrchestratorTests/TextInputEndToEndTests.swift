import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// TEXT-01 acceptance: text-input end-to-end proof — a full turn runs
/// through the orchestrator headlessly via MockLLMProvider +
/// StubToolDispatcher, demonstrating that voice and text share the same
/// entry point (only `TurnInput.source` differs).
@MainActor
final class TextInputEndToEndTests: XCTestCase {
    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    // MARK: - Fixture helpers

    /// Script pair for the get_time turn:
    /// Call 1 — textDelta("Let me check. ") → toolUseRequested(get_time) →
    ///          stopReason(.toolUse)
    /// Call 2 — textDelta("It's ") → textDelta("22:57 ") → textDelta("UTC") →
    ///          stopReason(.endTurn) → usage(...)
    private func getTimeScripts() -> [MockLLMProvider.Script] {
        let toolReq = ToolUseRequest(id: "tu1", name: "get_time", argsJSON: Data("{}".utf8))
        return [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
                .textDelta("Let me check. "),
                .toolUseRequested(toolReq),
                .stopReason(.toolUse),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "claude-opus-4-7", usagePrefix: nil)),
                .textDelta("It's "),
                .textDelta("22:57 "),
                .textDelta("UTC"),
                .usage(TurnUsage(inputTokens: 120, outputTokens: 4, cacheCreationInputTokens: 0, cacheReadInputTokens: 0)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ]
    }

    private func buildOrchestrator() async throws -> (AgentOrchestrator, ReplayLog, MockLLMProvider) {
        let mock = MockLLMProvider(scripts: getTimeScripts())
        let dispatcher = StubToolDispatcher(dispatch: { _ in Data("22:57 UTC".utf8) })
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "text01")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: dispatcher,
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: [
                ToolSchema(name: "get_time",
                           description: "current time",
                           inputSchema: Data("{}".utf8)),
            ]
        )
        return (orch, replay, mock)
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

    // MARK: - TE1: Full event sequence captured

    /// TE1 (critical TEXT-01 proof): submit text input, run the scripted
    /// two-call turn, capture all OrchestratorEvents. Assertions:
    /// - tokenDeltas concatenated → "Let me check. It's 22:57 UTC"
    /// - exactly one .toolCardUpdate(.completed) for get_time
    /// - exactly one .turnEnd(.endTurn)
    /// - exactly one .usage event (from the second stream call)
    func test_TE1_textInputEndToEnd_getTimeScenario() async throws {
        let (orch, _, _) = try await buildOrchestrator()
        let outcome = await orch.submit(.text("what time is it"))
        guard case .ran = outcome else { return XCTFail("expected .ran, got \(outcome)") }

        let events = await collectUntilIdle(orch: orch)

        let tokenText = events.compactMap { ev -> String? in
            if case .tokenDelta(_, let s) = ev { return s }
            return nil
        }.joined()
        XCTAssertEqual(tokenText, "Let me check. It's 22:57 UTC",
                       "full token sequence must match the scripted pair")

        let completedToolCards = events.filter { ev in
            if case .toolCardUpdate(let u) = ev, u.phase == .completed, u.toolName == "get_time" {
                return true
            }
            return false
        }
        XCTAssertEqual(completedToolCards.count, 1, "exactly one completed get_time tool card")

        let turnEnds = events.filter { ev in
            if case .turnEnd(_, let r) = ev, r == .endTurn { return true }
            return false
        }
        XCTAssertEqual(turnEnds.count, 1, "exactly one turnEnd(.endTurn)")

        let usageEvents = events.filter { ev in
            if case .usage = ev { return true }
            return false
        }
        XCTAssertEqual(usageEvents.count, 1, "exactly one usage event")
    }

    // MARK: - TE2: Replay log captures the turn

    /// TE2: ReplayLog receives the turn's events. Verified by querying the
    /// DB directly: the turns row must have started_at + ended_at set, AND
    /// the events table must contain at least one text_delta and one
    /// tool_call_requested event for the turn.
    func test_TE2_replayLogReceivesTurn() async throws {
        let (orch, replay, _) = try await buildOrchestrator()
        let outcome = await orch.submit(.text("what time is it"))
        guard case .ran(let turnId) = outcome else {
            return XCTFail("expected .ran outcome, got \(outcome)")
        }
        _ = await collectUntilIdle(orch: orch)

        await replay.flush()
        try await replay.close()

        // HI-02: real DB-row assertions (not file-size proxy).
        let conn = try SQLiteConnection.open(at: tempHome.dbURL)
        defer { try? conn.close() }

        // Turn row exists with ended_at + started_at both set.
        let turnRows: [(startedNull: Bool, endedNull: Bool)] = try conn.query(
            "SELECT started_at, ended_at FROM turns WHERE turn_id=?;",
            bindings: [.text(turnId.rawValue)],
            map: { ($0.columnIsNull(at: 0), $0.columnIsNull(at: 1)) }
        )
        XCTAssertEqual(turnRows.count, 1, "expected one turns row for the test turn")
        XCTAssertFalse(turnRows[0].startedNull, "started_at must be set")
        XCTAssertFalse(turnRows[0].endedNull, "ended_at must be set after turn end")

        // At least one text_delta event for the turn.
        let textDeltaCount: Int64 = try conn.query(
            "SELECT COUNT(*) FROM events WHERE turn_id=? AND kind='text_delta';",
            bindings: [.text(turnId.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertGreaterThanOrEqual(textDeltaCount, 1,
                                    "expected ≥1 text_delta events; got \(textDeltaCount)")

        // At least one tool_call_requested event (the get_time tool).
        let toolCallCount: Int64 = try conn.query(
            "SELECT COUNT(*) FROM events WHERE turn_id=? AND kind='tool_call_requested';",
            bindings: [.text(turnId.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertGreaterThanOrEqual(toolCallCount, 1,
                                    "expected ≥1 tool_call_requested events; got \(toolCallCount)")
    }

    // MARK: - TE3: text and voice produce identical event sequences

    /// TE3 (TEXT-01 acceptance): the orchestrator entry is unified. Voice and
    /// text turns produce byte-identical OrchestratorEvent sequences (modulo
    /// the fresh per-turn TurnID). Prove by running the same scripted turn
    /// twice — once with TurnInput.text, once with TurnInput.voice — and
    /// comparing event kinds.
    func test_TE3_textAndVoiceParity() async throws {
        let (orchText, _, _) = try await buildOrchestrator()
        _ = await orchText.submit(.text("what time is it"))
        let textEvents = await collectUntilIdle(orch: orchText)

        // Fresh fixture — ReplayLog wants a clean DB file per run.
        tempHome?.cleanup()
        tempHome = TempReplayHome.make()

        let (orchVoice, _, _) = try await buildOrchestrator()
        _ = await orchVoice.submit(.voice("what time is it"))
        let voiceEvents = await collectUntilIdle(orch: orchVoice)

        // Compare the ORDERED sequence of event kinds (ignoring turnId/text
        // payload). The kinds must match exactly.
        func kinds(_ evs: [OrchestratorEvent]) -> [String] {
            evs.map { ev in
                switch ev {
                case .stateChange(let s):  return "stateChange(\(s))"
                case .tokenDelta:          return "tokenDelta"
                case .thinkingDelta:       return "thinkingDelta"
                case .toolCardUpdate(let u): return "toolCardUpdate(\(u.phase))"
                case .usage:               return "usage"
                case .turnEnd:             return "turnEnd"
                case .error:               return "error"
                }
            }
        }
        XCTAssertEqual(kinds(textEvents), kinds(voiceEvents),
                       "text and voice turns must produce identical event-kind sequences")
    }

    // MARK: - TE4: Tool result is nonce-wrapped in model-facing messages

    /// TE4: The tool_result delivered to the second provider.stream call is
    /// wrapped in the per-turn UntrustedWrapper envelope. Verified by
    /// inspecting `MockLLMProvider.recordedCalls[1].messages` for a `.tool`
    /// message whose content carries the `<UNTRUSTED_CONTENT id="...">`
    /// envelope (SEC-06).
    func test_TE4_toolResultWrappedWithNonce() async throws {
        let (orch, _, mock) = try await buildOrchestrator()
        _ = await orch.submit(.text("what time is it"))
        _ = await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2, "expected 2 provider.stream calls (tool loop)")

        let secondCallToolMsg = calls[1].messages.first(where: { $0.role == .tool })
        XCTAssertNotNil(secondCallToolMsg, "second call must include a .tool role message")
        guard let msg = secondCallToolMsg else { return }
        guard case .toolResult(_, let content) = msg.content[0] else {
            return XCTFail("expected toolResult content")
        }
        XCTAssertTrue(content.contains("<UNTRUSTED_CONTENT id="),
                      "tool result must be wrapped in the nonce envelope (SEC-06)")
        XCTAssertTrue(content.contains("22:57 UTC"),
                      "tool result content must carry the dispatcher's output")
    }
}
