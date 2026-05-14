import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// Task 6 (local-first LLM routing spec §2, §3): reactive escalation from
/// Ollama → Anthropic when the local provider emits a
/// `providerError(ollamaFailureKind: ...)`. Budget: at most ONE escalation
/// per turn; second failure surfaces a terminal error. Disabling
/// `escalationEnabled` short-circuits the retry entirely.
@MainActor
final class LocalFirstEscalationTests: XCTestCase {
    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Build a `PerTurnSnapshot` honouring `escalationEnabled`. The fixture in
    /// `Helpers.swift` doesn't expose the flag because pre-Task-3 snapshots
    /// always defaulted to `true`; this test file forces the flag explicitly.
    private func snapshot(
        provider: ProviderSelection,
        escalationEnabled: Bool
    ) -> PerTurnSnapshot {
        let providerString = provider.rawValue
        let json = """
        {"schemaVersion":1,"provider":"\(providerString)","escalationEnabled":\(escalationEnabled),"tts":{"tier":"tier1"},"stt":{"whisperKitFallback":false},"featureFlags":{}}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(PerTurnSnapshot.self, from: json)
    }

    private func buildOrchestrator(
        provider mock: MockLLMProvider,
        configStore cs: ConfigStore
    ) async throws -> (AgentOrchestrator, ReplayLog) {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "abc")
        let orch = AgentOrchestrator(
            configStore: cs,
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

    // MARK: - A. Reactive fallback fires once on malformedToolCall

    /// Provider running on Ollama emits providerError(.malformedToolCall) on
    /// the first call; orchestrator escalates to Anthropic; second call
    /// returns a clean happy-path stream. Exactly one `.escalated` event;
    /// the turn ends cleanly.
    func test_A_reactiveFallbackFiresOnceOnMalformedToolCall() async throws {
        let mock = MockLLMProvider(scripts: [
            // First attempt (Ollama): malformed tool call surfaces as
            // providerError mid-stream. The Ollama provider always emits
            // .messageStart before any failure detection (see Task 5).
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "qwen", usagePrefix: nil)),
                .providerError(.malformedToolCall(reason: "tool args were not valid JSON")),
            ]),
            // Second attempt (Anthropic after escalation): completes cleanly.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "opus", usagePrefix: nil)),
                .textDelta("Hello."),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let cs = ConfigStore(
            launch: makeLaunchSnapshot(),
            initial: snapshot(provider: .ollama, escalationEnabled: true)
        )
        let (orch, _) = try await buildOrchestrator(provider: mock, configStore: cs)

        _ = await orch.submit(.text("ping"))
        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // Exactly one escalation event observed with reason == .malformedToolCall.
        let escalations: [EscalationDecision] = events.compactMap { ev in
            if case .escalated(let d) = ev { return d }
            return nil
        }
        XCTAssertEqual(escalations.count, 1, "expected exactly one escalation; got \(escalations.count) in \(events)")
        XCTAssertEqual(escalations.first?.reason, .malformedToolCall)
        XCTAssertEqual(escalations.first?.from, .ollama)
        XCTAssertEqual(escalations.first?.to, .anthropic)

        // Turn ended cleanly (no terminal error).
        let sawError = events.contains { ev in
            if case .error = ev { return true }; return false
        }
        XCTAssertFalse(sawError, "turn should end cleanly post-escalation; got \(events)")
        XCTAssertTrue(events.contains(where: { ev in
            if case .turnEnd(_, let r) = ev, r == .endTurn { return true }; return false
        }), "expected terminal .turnEnd(.endTurn) on Anthropic")

        // Two provider calls: Ollama (failed) + Anthropic (succeeded).
        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2, "expected one escalation → 2 provider calls; got \(calls.count)")
    }

    // MARK: - B. Escalation budget honoured (both providers fail)

    /// Ollama emits providerError(.malformedToolCall); Anthropic (post-
    /// escalation) ALSO emits a providerError. Orchestrator does NOT
    /// escalate a second time — surfaces a terminal error. Exactly one
    /// `.escalated` event.
    func test_B_escalationBudgetHonoredBothProvidersFail() async throws {
        let mock = MockLLMProvider(scripts: [
            // First attempt (Ollama): malformedToolCall.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "qwen", usagePrefix: nil)),
                .providerError(.malformedToolCall(reason: "bad tool args")),
            ]),
            // Second attempt (Anthropic post-escalation): emptyResponse —
            // doesn't matter that it's an Ollama-flavoured kind; the
            // orchestrator's budget check is purely on escalatedThisTurn,
            // not on the kind. We just need a providerError outcome.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "opus", usagePrefix: nil)),
                .providerError(.api(statusCode: 500, body: "upstream borked")),
            ]),
            // Third attempt sentinel — must NOT be invoked.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "should-not-fire", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let cs = ConfigStore(
            launch: makeLaunchSnapshot(),
            initial: snapshot(provider: .ollama, escalationEnabled: true)
        )
        let (orch, _) = try await buildOrchestrator(provider: mock, configStore: cs)

        _ = await orch.submit(.text("ping"))
        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // Exactly one escalation event.
        let escalations: [EscalationDecision] = events.compactMap { ev in
            if case .escalated(let d) = ev { return d }
            return nil
        }
        XCTAssertEqual(escalations.count, 1, "expected exactly one escalation despite second failure")

        // Terminal .error event present.
        let sawError = events.contains { ev in
            if case .error = ev { return true }; return false
        }
        XCTAssertTrue(sawError, "second failure must surface a terminal error; got \(events)")

        // Exactly two provider calls: no third attempt.
        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2, "must NOT escalate twice; got \(calls.count) calls")
    }

    // MARK: - C. Escalation disabled surfaces error directly

    /// `escalationEnabled == false`, provider is .ollama, providerError
    /// fires. Orchestrator does NOT escalate; surfaces a terminal error and
    /// calls the provider only ONCE.
    func test_C_escalationDisabledSurfacesErrorDirectly() async throws {
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "qwen", usagePrefix: nil)),
                .providerError(.malformedToolCall(reason: "bad tool args")),
            ]),
            // Sentinel — must NOT be invoked.
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "should-not-fire", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let cs = ConfigStore(
            launch: makeLaunchSnapshot(),
            initial: snapshot(provider: .ollama, escalationEnabled: false)
        )
        let (orch, _) = try await buildOrchestrator(provider: mock, configStore: cs)

        _ = await orch.submit(.text("ping"))
        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // ZERO escalation events.
        let escalations: [EscalationDecision] = events.compactMap { ev in
            if case .escalated(let d) = ev { return d }
            return nil
        }
        XCTAssertEqual(escalations.count, 0, "escalationEnabled=false must NOT emit .escalated; got \(escalations)")

        // Terminal .error event surfaced.
        let sawError = events.contains { ev in
            if case .error = ev { return true }; return false
        }
        XCTAssertTrue(sawError, "disabled escalation must surface a terminal error; got \(events)")

        // Exactly one provider call.
        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 1, "disabled escalation must NOT retry; got \(calls.count) calls")
    }
}
