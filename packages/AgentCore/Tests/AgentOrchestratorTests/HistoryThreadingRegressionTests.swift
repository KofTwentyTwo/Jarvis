import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// **B-02 carry-forward bug — tactical patch regression coverage.**
///
/// Pinned by `JARVIS-API-MIGRATION-PLAN.md §3` outside the M-0..M-7
/// migration sequence: orchestrator must prepend prior turn history to
/// the messages array before the current user message, and the prepend
/// must NOT trigger Phase E's `streamTruncated` retry (R-006 mitigation
/// pinning the 2026-05-03 audit's cache-eligibility gate behavior).
///
/// The patch threads history via an injected `SessionHistoryLookup`
/// closure (no `Memory` package dep — AgentCore stays decoupled).
/// Production wiring lives in `AppDelegate.installAgent` and reads from
/// `MemoryStore.recentTurnsForSession`.
@MainActor
final class HistoryThreadingRegressionTests: XCTestCase {

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
        history: [AgentOrchestrator.PriorTurn]
    ) async throws -> (AgentOrchestrator, ReplayLog, SessionID) {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let frozen = history  // value-capture for the @Sendable closure
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: [],
            sessionHistoryLookup: { frozen }
        )
        return (orch, replay, session)
    }

    /// Drain `events` until `predicate` matches, with a timeout.
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

    // MARK: - HT-1

    /// HT-1: a turn with two prior pairs in the lookup MUST send a messages
    /// array containing `[system, .user("ok"), .assistant("ack"), .user("yes"),
    /// .assistant("ack2"), .user("why?")]` — chronological, alternating, with
    /// the current user message LAST. This is the B-02 fix made falsifiable.
    func test_HT1_thirdTurnIncludesPriorTwoUserAssistantPairs() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let history: [AgentOrchestrator.PriorTurn] = [
            .init(role: .user, content: "ok"),
            .init(role: .assistant, content: "ack"),
            .init(role: .user, content: "yes"),
            .init(role: .assistant, content: "ack2"),
        ]
        let (orch, _, _) = try await buildOrchestrator(provider: mock, history: history)

        let outcome = await orch.submit(.text("why?"))
        guard case .ran = outcome else { return XCTFail("expected .ran, got \(outcome)") }

        // Drain to idle so the call is recorded.
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }
            return false
        }

        let recorded = await mock.getRecordedCalls()
        XCTAssertEqual(recorded.count, 1, "expected one stream call for the single turn")
        let msgs = recorded[0].messages

        // System first.
        XCTAssertEqual(msgs.first?.role, .system, "first message must be .system")

        // Roles after system: user, assistant, user, assistant, user.
        let nonSystem = msgs.dropFirst().map { $0.role }
        XCTAssertEqual(
            Array(nonSystem),
            [.user, .assistant, .user, .assistant, .user],
            "prior history must precede current user message in chronological order"
        )

        // Content equality on the prior-history slice.
        let textOf: (LLMMessage) -> String? = { msg in
            for block in msg.content {
                if case let .text(s) = block { return s }
            }
            return nil
        }
        XCTAssertEqual(textOf(msgs[1]), "ok")
        XCTAssertEqual(textOf(msgs[2]), "ack")
        XCTAssertEqual(textOf(msgs[3]), "yes")
        XCTAssertEqual(textOf(msgs[4]), "ack2")
        XCTAssertEqual(textOf(msgs[5]), "why?")
    }

    // MARK: - HT-2

    /// HT-2: with an empty history (the default `emptySessionHistoryLookup`),
    /// behavior is identical to pre-B-02: `[system, current-user]`. Regression
    /// guard so the default-closure path doesn't silently inject anything.
    func test_HT2_emptyHistoryProducesSystemPlusUserOnly() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let (orch, _, _) = try await buildOrchestrator(provider: mock, history: [])

        _ = await orch.submit(.text("hello"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }
            return false
        }

        let recorded = await mock.getRecordedCalls()
        XCTAssertEqual(recorded.count, 1)
        let roles = recorded[0].messages.map { $0.role }
        XCTAssertEqual(roles, [.system, .user])
    }

    // MARK: - HT-3 (R-006 mitigation — Phase E gate behavior)

    /// HT-3: three short turns. The B-02 patch MUST NOT cause any
    /// `.streamTruncatedFinal` event to land on the bus. The patch grows
    /// the *messages* array, not the system prompt — Phase E's
    /// `CacheHints.eligibleForSystemPrompt(finalSystem)` gate is computed
    /// from the system prompt alone, so the cache-eligibility flip the
    /// 2026-05-03 audit fixed is unaffected by this change. This test
    /// pins that property: a normal happy-path sequence emits ZERO
    /// `streamTruncated` retry events.
    ///
    /// Note: MockLLMProvider doesn't produce real Anthropic responses, so
    /// this test cannot reproduce the *network-side* streamTruncated.
    /// It pins the orchestrator-side invariant: no retry path is
    /// reached when the provider behaves normally. The full integration
    /// signal lives in the env-flag-gated AnthropicProviderTests
    /// (`JARVIS_REAL_MODELS=1`).
    func test_HT3_twoShortTurnsThenThird_NoStreamTruncatedRetries() async throws {
        // Build with one prior pair to exercise the patched path while
        // keeping the system prompt small (the cache-eligibility gate
        // input).
        let history: [AgentOrchestrator.PriorTurn] = [
            .init(role: .user, content: "ok"),
            .init(role: .assistant, content: "ack"),
        ]
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m3", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let (orch, _, _) = try await buildOrchestrator(provider: mock, history: history)

        // Drain to idle between submits — orchestrator rejects concurrent
        // submits, so we serialize.
        var allEvents: [OrchestratorEvent] = []
        for text in ["ok", "yes", "why?"] {
            let outcome = await orch.submit(.text(text))
            guard case .ran = outcome else {
                return XCTFail("submit(\(text)) expected .ran, got \(outcome)")
            }
            let drained = await collectUntil(orch: orch) { ev in
                if case .stateChange(.idle) = ev { return true }
                return false
            }
            allEvents.append(contentsOf: drained)
        }

        // R-006 regression: ZERO streamTruncatedFinal across the three turns.
        // The orchestrator surfaces a terminal streamTruncated via
        // `.error(turnId:, error: .streamTruncatedFinal)` (LLMProviderError),
        // not via `.turnEnd`.
        for event in allEvents {
            if case let .error(_, providerError) = event {
                XCTAssertNotEqual(
                    providerError,
                    LLMProviderError.streamTruncatedFinal,
                    "B-02 patch must not introduce streamTruncatedFinal — pins Phase E gate behavior (R-006)"
                )
            }
        }
    }
}
