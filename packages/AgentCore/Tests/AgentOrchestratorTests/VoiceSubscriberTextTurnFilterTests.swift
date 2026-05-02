import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// Phase 9 / Plan 4 / BLOCKER-2 prove-out.
///
/// The voice-event translator subscriber installed by AppDelegate.installAgent
/// drives a per-turn assistant-text accumulator and emits `turnEnded` to the
/// VoiceOrchestratorAdapter ONLY when the turn was voice-originated (queried
/// via `AgentOrchestrator.turnSourceWasVoice`). Without this filter, a
/// text-originated `.turnEnd` would drive VoiceController back to `.idle`
/// from `.listening` — silently breaking voice on every text message.
///
/// This test replicates the subscriber-drain logic in-test and asserts:
///   - voice-originated turns DO drive emitTurnEnded
///   - text-originated turns do NOT
///   - the per-turn accumulator concatenates assistant text correctly
@MainActor
final class VoiceSubscriberTextTurnFilterTests: XCTestCase {

    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    /// Spy that records emitTurnEnded calls — surrogate for VoiceOrchestratorAdapter.
    actor EmitSpy {
        var turnEnded: [(turnId: TurnID, finalText: String)] = []
        var errors: [TurnID] = []
        func recordTurnEnded(turnId: TurnID, finalText: String) {
            turnEnded.append((turnId, finalText))
        }
        func recordError(turnId: TurnID) {
            errors.append(turnId)
        }
        func snapshot() -> (turnEnded: [(turnId: TurnID, finalText: String)], errors: [TurnID]) {
            (turnEnded, errors)
        }
    }

    /// Full pipeline: real AgentOrchestrator + real OrchestratorEventBroadcaster
    /// + real .voice subscriber drain (functional copy of AppDelegate's). Drives
    /// a deterministic mix of voice + text turns and asserts emitTurnEnded
    /// fires ONLY for voice turns.
    func testVoiceSubscriberIgnoresTextOriginatedTurns() async throws {
        // 1. Build a mock provider that emits a tiny stream per turn.
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .textDelta("hello"),
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
        )

        // 2. Set up the broadcaster + voice subscriber drain (matches
        //    AppDelegate.installAgent step 5e).
        let broadcaster = OrchestratorEventBroadcaster(upstream: orch.events)
        await broadcaster.start()
        let voiceSub = await broadcaster.subscribe(priority: .voice, capacity: 64)

        let spy = EmitSpy()
        let drainTask = Task {
            var perTurnAssistantText: [TurnID: String] = [:]
            for await event in voiceSub.stream {
                switch event {
                case let .tokenDelta(turnId, text):
                    let isVoice = await orch.turnSourceWasVoice(turnId)
                    guard isVoice else { continue }
                    perTurnAssistantText[turnId, default: ""] += text
                case let .turnEnd(turnId, _):
                    let isVoice = await orch.turnSourceWasVoice(turnId)
                    if isVoice {
                        let finalText = perTurnAssistantText.removeValue(forKey: turnId) ?? ""
                        await spy.recordTurnEnded(turnId: turnId, finalText: finalText)
                    } else {
                        perTurnAssistantText.removeValue(forKey: turnId)
                    }
                case let .error(turnId, _):
                    let isVoice = await orch.turnSourceWasVoice(turnId)
                    if isVoice {
                        await spy.recordError(turnId: turnId)
                        perTurnAssistantText.removeValue(forKey: turnId)
                    }
                default:
                    break
                }
            }
        }

        // 3. Drive a deterministic sequence: voice → text → voice.
        guard case .ran(let voice1) = await orch.submit(.voice("v1")) else {
            return XCTFail("expected .ran for voice")
        }
        await drainUntilIdle(orch: orch)

        guard case .ran(let text1) = await orch.submit(.text("t1")) else {
            return XCTFail("expected .ran for text")
        }
        await drainUntilIdle(orch: orch)

        guard case .ran(let voice2) = await orch.submit(.voice("v2")) else {
            return XCTFail("expected .ran for voice 2")
        }
        await drainUntilIdle(orch: orch)

        // Give the subscriber drain a moment to process the trailing turnEnd.
        try await Task.sleep(for: .milliseconds(100))

        // 4. Assertions: spy recorded exactly two turnEnded calls — voice1 + voice2.
        let snapshot = await spy.snapshot()
        XCTAssertEqual(
            snapshot.turnEnded.count, 2,
            "expected exactly 2 emitTurnEnded calls (voice turns); got \(snapshot.turnEnded.count)"
        )
        let recordedIds = Set(snapshot.turnEnded.map { $0.turnId })
        XCTAssertTrue(recordedIds.contains(voice1), "voice1 should fire emitTurnEnded")
        XCTAssertTrue(recordedIds.contains(voice2), "voice2 should fire emitTurnEnded")
        XCTAssertFalse(recordedIds.contains(text1), "text1 must NOT fire emitTurnEnded (BLOCKER-2 cardinal)")

        // Each voice turn's accumulated assistant text was "hello".
        for entry in snapshot.turnEnded {
            XCTAssertEqual(entry.finalText, "hello", "voice turn \(entry.turnId) finalText mismatch")
        }

        // 5. Cleanup.
        drainTask.cancel()
        await broadcaster.stop()
    }

    private func drainUntilIdle(orch: AgentOrchestrator, timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        // Use a fresh subscriber on a NEW broadcaster... actually for simplicity,
        // wait for currentTurn to clear or rely on the orch.events drain which
        // is already consumed by our broadcaster. Sleep briefly.
        // (The broadcaster owns orch.events; we can't iterate it again here.
        // Polling _testCurrentTurnId is safe and matches the orchestrator's
        // existing test seam.)
        while Date() < deadline {
            let active = await orch._testCurrentTurnId()
            if active == nil { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
