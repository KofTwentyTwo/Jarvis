import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// Plan 09-02 / BLOCKER-2 — proves AgentOrchestrator tracks voice-originated
/// turns. Without this, Plan 4's voice subscriber accumulates `.tokenDelta`
/// events across all turn types and would fire `emitTurnEnded` for
/// text-originated turns — driving `VoiceController` back to `.idle` from
/// `.listening` whenever the user sends a text message.
@MainActor
final class AgentOrchestratorVoiceTurnTrackingTests: XCTestCase {

    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    // MARK: - Helper

    private func buildOrchestrator() async throws -> (AgentOrchestrator, MockLLMProvider) {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
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
            availableTools: []
            // visionRouter intentionally nil — BLOCKER-2 is independent of vision.
        )
        return (orch, mock)
    }

    private func collectUntilIdle(orch: AgentOrchestrator, timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        for await event in orch.events {
            if case .stateChange(.idle) = event { return }
            if Date() > deadline { return }
        }
    }

    // MARK: - Tests

    /// Test 7 — voice-originated turn is tracked.
    func testTurnSourceWasVoiceReturnsTrueForVoiceSubmission() async throws {
        let (orch, _) = try await buildOrchestrator()

        guard case .ran(let turnId) = await orch.submit(.voice("hi")) else {
            return XCTFail("expected .ran for voice submission")
        }
        await collectUntilIdle(orch: orch)

        let wasVoice = await orch.turnSourceWasVoice(turnId)
        XCTAssertTrue(wasVoice, "voice-originated turn should be tracked in voiceOriginatedTurns")
    }

    /// Test 8 — text-originated turn is NOT tracked.
    func testTurnSourceWasVoiceReturnsFalseForTextSubmission() async throws {
        let (orch, _) = try await buildOrchestrator()

        guard case .ran(let turnId) = await orch.submit(.text("hi")) else {
            return XCTFail("expected .ran for text submission")
        }
        await collectUntilIdle(orch: orch)

        let wasVoice = await orch.turnSourceWasVoice(turnId)
        XCTAssertFalse(wasVoice, "text-originated turn must NOT be tracked")
    }

    /// Test 9 — unknown turnId returns false (no false positive).
    func testTurnSourceWasVoiceReturnsFalseForUnknownTurnId() async throws {
        let (orch, _) = try await buildOrchestrator()
        let stranger = TurnID.fresh()
        let wasVoice = await orch.turnSourceWasVoice(stranger)
        XCTAssertFalse(wasVoice, "never-submitted turnId must NOT report as voice")
    }
}
