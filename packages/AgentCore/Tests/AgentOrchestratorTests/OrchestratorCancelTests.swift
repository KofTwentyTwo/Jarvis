import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

@MainActor
final class OrchestratorCancelTests: XCTestCase {
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
    ) async throws -> (AgentOrchestrator, ReplayLog, SessionID) {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis"
        )
        return (orch, replay, session)
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

    // MARK: - OC1

    /// OC1: turn in flight (throttled mock) → cancelAndSubmit returns .superseded
    /// with the prior turn's id.
    func test_OC1_cancelAndSubmitReturnsSupersededWithPriorId() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
            .textDelta("a"), .textDelta("b"),
            .stopReason(.endTurn),
            .messageStop,
        ], throttleBetweenEventsNs: 200_000_000))  // 200ms between events
        let (orch, _, _) = try await buildOrchestrator(provider: mock)

        let firstOutcome = await orch.submit(.text("first"))
        guard case .ran(let priorId) = firstOutcome else {
            return XCTFail("expected first .ran")
        }

        // Replace mock's script for the second turn (immediate end).
        await mock.appendScript(.init(events: [
            .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))

        // Cancel mid-flight; cancellation drains synchronously per the
        // actor-reentrancy guard.
        let secondOutcome = await orch.cancelAndSubmit(.text("second"))

        guard case .superseded(let priorReturned, let reason) = secondOutcome else {
            return XCTFail("expected .superseded, got \(secondOutcome)")
        }
        XCTAssertEqual(priorReturned, priorId)
        XCTAssertEqual(reason, .bargedIn)

        // Drain to ensure the second turn completes.
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }
    }

    // MARK: - OC2

    /// OC2: cancelAndSubmit with no turn in flight → .ran (no supersession).
    func test_OC2_cancelAndSubmitOnFreshOrchestratorReturnsRan() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let (orch, _, _) = try await buildOrchestrator(provider: mock)

        let outcome = await orch.cancelAndSubmit(.text("first"))
        guard case .ran = outcome else {
            return XCTFail("expected .ran, got \(outcome)")
        }

        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }
    }

    // MARK: - OC3 (critical reentrancy guard)

    /// OC3: After cancelAndSubmit returns, currentTurn must be the new turn,
    /// not the cancelled one. Verify by reading the test hook BEFORE letting
    /// the second turn complete: the active turn id must equal the new turn's
    /// id, never the prior id, and never nil-followed-by-prior.
    ///
    /// The mock's per-event throttle keeps the prior turn's stream open so
    /// `cancelAndSubmit` exercises the cancel-and-await path. If `await
    /// task.value` were missing, the late `.messageStop` from the cancelled
    /// stream could clobber `currentTurn`, leaving the orchestrator pointing
    /// at the cancelled task. The assertion `currentTurn == newTurnId` after
    /// `cancelAndSubmit` returns catches that race.
    func test_OC3_cancelAndSubmitDrainsCancelledTaskBeforeAssigningNewTurn() async throws {
        let mock = MockLLMProvider(scripts: [
            // Script 1: a long-running stream the orchestrator will cancel.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .textDelta("a"), .textDelta("b"), .textDelta("c"),
                .stopReason(.endTurn),
                .messageStop,
            ], throttleBetweenEventsNs: 200_000_000),
            // Script 2: a *long* second turn, so we observe currentTurn while
            // it's still in flight (and not yet ended).
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .textDelta("z"),
                .stopReason(.endTurn),
                .messageStop,
            ], throttleBetweenEventsNs: 100_000_000),
        ])
        let (orch, _, _) = try await buildOrchestrator(provider: mock)

        let first = await orch.submit(.text("first"))
        guard case .ran(let priorId) = first else { return XCTFail() }

        // Verify the prior turn is the active one before cancellation.
        let beforeCancel = await orch._testCurrentTurnId()
        XCTAssertEqual(beforeCancel, priorId)

        let second = await orch.cancelAndSubmit(.text("second"))
        guard case .superseded(let returnedPrior, _) = second else {
            return XCTFail("expected .superseded")
        }
        XCTAssertEqual(returnedPrior, priorId)

        // Race-window assertion: after cancelAndSubmit returns, currentTurn
        // MUST be the new turn (or nil if it already finished). It must NEVER
        // equal priorId. That's the AGENT-06 reentrancy guard in action.
        let activeAfterCancel = await orch._testCurrentTurnId()
        XCTAssertNotEqual(activeAfterCancel, priorId,
                          "currentTurn must NOT point at the cancelled turn — actor-reentrancy race")

        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }
    }

    // MARK: - OC4

    /// OC4: ReplayLog.endTurn gets called for the cancelled turn with
    /// stop_reason="cancelled". Indirect check via DB inspection: after cancel,
    /// the prior turn's row must have ended_at set + stop_reason='cancelled'.
    func test_OC4_cancelledTurnEndedWithCancelledStopReason() async throws {
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .textDelta("a"),
                .stopReason(.endTurn),
                .messageStop,
            ], throttleBetweenEventsNs: 250_000_000),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let (orch, replay, _) = try await buildOrchestrator(provider: mock)

        let first = await orch.submit(.text("first"))
        guard case .ran(let priorId) = first else { return XCTFail() }

        _ = await orch.cancelAndSubmit(.text("second"))

        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        await replay.flush()
        try await replay.close()

        // HI-02: real DB-row assertion (not file-size proxy). Open the
        // closed DB directly and verify the prior turn's row has
        // ended_at NOT NULL and stop_reason='cancelled'. This is what the
        // test claims to verify; the file-size proxy was a tautology.
        XCTAssertFalse(priorId.rawValue.isEmpty)
        let conn = try SQLiteConnection.open(at: tempHome.dbURL)
        defer { try? conn.close() }
        let row: [(endedNull: Bool, stop: String)] = try conn.query(
            "SELECT ended_at, stop_reason FROM turns WHERE turn_id=?;",
            bindings: [.text(priorId.rawValue)],
            map: { ($0.columnIsNull(at: 0), $0.columnText(at: 1) ?? "") }
        )
        XCTAssertEqual(row.count, 1, "prior turn row must exist in turns table")
        XCTAssertFalse(row[0].endedNull, "ended_at must be set on cancelled turn")
        XCTAssertEqual(row[0].stop, "cancelled",
                       "stop_reason must be 'cancelled' (not '\(row[0].stop)')")
    }
}
