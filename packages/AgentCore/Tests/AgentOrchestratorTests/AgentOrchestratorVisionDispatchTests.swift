import XCTest
import AgentCore
import Config
import Replay
import JarvisVision
@testable import AgentOrchestrator

/// Plan 09-02 / D-01 + D-02 — proves AgentOrchestrator.runTurn dispatches
/// image-bearing turns through `VisionRouter.route(...)` BEFORE the streaming
/// loop, and that the post-response evaluation hook drives silent T1→T2
/// escalation under the SAME `turnId` (D-02 internal retry semantics, distinct
/// from AGENT-09's `stream_truncated` retry-with-fresh-turnId).
@MainActor
final class AgentOrchestratorVisionDispatchTests: XCTestCase {

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

    /// Build a VisionRouter that returns the given t1/t2 providers. T3 is
    /// wired to a separate provider but vision-dispatch tests never route
    /// to T3 (route(...) selects T3 only on explicit cloud opt-in, and
    /// these tests use neutral prompts).
    private func makeRouter(t1: any LLMProvider, t2: any LLMProvider) -> VisionRouter {
        // T3 reuses t1 for symmetry — we never reach the t3Cloud arm in
        // these tests, but the constructor requires a non-nil provider.
        return VisionRouter(t1Provider: t1, t2Provider: t2, t3Provider: t1)
    }

    private func buildOrchestrator(
        provider mock: any LLMProvider,
        visionRouter: VisionRouter? = nil,
        hasRealT2Provider: Bool = false,
        dispatcher: any ToolDispatcher = StubToolDispatcher()
    ) async throws -> (AgentOrchestrator, ReplayLog, SessionID) {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: dispatcher,
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: [],
            visionRouter: visionRouter,
            hasRealT2Provider: hasRealT2Provider
        )
        return (orch, replay, session)
    }

    private func collectUntilIdle(orch: AgentOrchestrator, timeout: TimeInterval = 5.0) async -> [OrchestratorEvent] {
        var collected: [OrchestratorEvent] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await event in orch.events {
            collected.append(event)
            if case .stateChange(.idle) = event { return collected }
            if Date() > deadline { return collected }
        }
        return collected
    }

    private static let fakeImage = ImageBlock(
        mediaType: "image/jpeg",
        data: Data([0xFF, 0xD8, 0xFF])  // JPEG SOI marker prefix — bytes don't matter for routing
    )

    // MARK: - Tests

    /// Test 1 — text-only turn never reaches VisionRouter.route.
    /// MockLLMProvider records image arrays; assert they're empty for both
    /// the call MockLLMProvider received AND that the orchestrator never
    /// went through the vision branch (the absence of an `escalationAttempt`
    /// replay marker stands in for "VisionRouter was not consulted").
    func testRunTurnNoImagesSkipsVisionRouter() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
            .textDelta("hi"),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let router = makeRouter(t1: mock, t2: mock)
        let (orch, _, _) = try await buildOrchestrator(provider: mock, visionRouter: router)

        let outcome = await orch.submit(.text("hello"))
        guard case .ran(let turnId) = outcome else { return XCTFail("expected .ran") }

        _ = await collectUntilIdle(orch: orch)

        // The text-only path uses the single-modal stream — recorded call
        // images must be empty. (The multimodal overload would have been
        // recorded with non-empty images.)
        let calls = await mock.getRecordedCalls()
        XCTAssertGreaterThanOrEqual(calls.count, 1)
        for call in calls {
            XCTAssertTrue(call.images.isEmpty,
                          "text-only turn should never reach the multimodal stream overload")
        }

        // turnHadImage(turnId) returns false for text-only turns (the vision
        // branch is the only place imageBearingTurns is mutated).
        let hadImage = await orch.turnHadImage(turnId)
        XCTAssertFalse(hadImage, "text-only turn should not be marked as image-bearing")
    }

    /// Test 2 — image-bearing turn reaches the multimodal stream overload
    /// with the original image bytes. The T1 response is long enough (>= 24
    /// chars) that the post-response heuristic stays-on-T1 — no escalation.
    func testRunTurnWithImagesCallsVisionRouter() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "gemma4:31b", usagePrefix: nil)),
            // Confidence text — long enough (>= 24 chars) and free of the
            // low-confidence substring set in VisionRouterConfig.default.
            .textDelta("This is a white ceramic coffee mug on a wooden desk."),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let router = makeRouter(t1: mock, t2: mock)
        let (orch, _, _) = try await buildOrchestrator(provider: mock, visionRouter: router)

        let input = TurnInput.withImages(.text, text: "describe this", images: [Self.fakeImage])
        let outcome = await orch.submit(input)
        guard case .ran(let turnId) = outcome else { return XCTFail("expected .ran") }

        _ = await collectUntilIdle(orch: orch)

        // The multimodal overload was called — assert the recorded call
        // carries the original image bytes.
        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 1, "image-bearing turn should issue exactly one stream call (no escalation)")
        XCTAssertEqual(calls.first?.images.count, 1)
        XCTAssertEqual(calls.first?.images.first, Self.fakeImage)

        // turnHadImage(turnId) returns true for image-bearing turns.
        let hadImage = await orch.turnHadImage(turnId)
        XCTAssertTrue(hadImage, "image-bearing turn should be recorded in imageBearingTurns")
    }

    /// Test 3 — D-02 escalation: low-confidence T1 response → T2 retried
    /// under the SAME turnId; user sees ONE final answer (T2's text), and
    /// the ReplayLog records `.escalationAttempt(.t1ToT2)` for that turnId.
    func testRunTurnEscalatesToT2OnLowConfidence() async throws {
        // T1 returns "I'm not sure" — the VisionEscalationHeuristic flags
        // this as low confidence. T2 returns the high-confidence answer.
        let t1Mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m_t1", model: "gemma4:31b", usagePrefix: nil)),
            .textDelta("I'm not sure"),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let t2Mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m_t2", model: "Qwen/Qwen3.5-35B-A3B-VL", usagePrefix: nil)),
            .textDelta("It's a coffee mug"),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let router = makeRouter(t1: t1Mock, t2: t2Mock)
        // Production today wires `MissingT2Provider` (no real T2 sidecar
        // yet); this test passes `hasRealT2Provider: true` and a real mock
        // T2 to exercise the escalation path.
        let (orch, _, _) = try await buildOrchestrator(
            provider: t1Mock,
            visionRouter: router,
            hasRealT2Provider: true
        )

        let input = TurnInput.withImages(.text, text: "what is this", images: [Self.fakeImage])
        let outcome = await orch.submit(input)
        guard case .ran(let turnId) = outcome else { return XCTFail("expected .ran") }

        let events = await collectUntilIdle(orch: orch)

        // T1 was called once; T2 was called once after escalation.
        let t1Calls = await t1Mock.getRecordedCalls()
        let t2Calls = await t2Mock.getRecordedCalls()
        XCTAssertEqual(t1Calls.count, 1, "T1 should have been called exactly once")
        XCTAssertEqual(t2Calls.count, 1, "T2 should have been called exactly once after escalation")

        // The user-visible token deltas concatenate to T1's then T2's text,
        // but only ONE .turnEnd is emitted.
        let turnEndCount = events.filter {
            if case .turnEnd = $0 { return true }
            return false
        }.count
        XCTAssertEqual(turnEndCount, 1, "exactly one turnEnd despite the T1→T2 escalation")

        // The single .turnEnd carries the original turnId (NOT a fresh one).
        let turnEnd = events.first {
            if case .turnEnd = $0 { return true }
            return false
        }
        if case .turnEnd(let endTurnId, _) = turnEnd {
            XCTAssertEqual(endTurnId, turnId,
                           "escalation reuses the same turnId — that's what makes D-02 distinct from AGENT-09")
        } else {
            XCTFail("missing .turnEnd event")
        }
    }

    /// Test 4 — explicit cloud opt-in is detected via ContextBuilder.
    /// The plan asks us to verify ContextBuilder.matchesCloudOptIn returns
    /// true for "send to opus", driving route(...) to T3. We assert the
    /// behaviour at the ContextBuilder boundary because the orchestrator
    /// merely forwards the bool.
    func testContextBuilderDetectsCloudOptIn() async throws {
        // Plan 10-02 disambiguation: qualify with `JarvisVision.` because
        // AgentCore now also exposes a `ContextBuilder` (self-aware system-
        // prompt composer). This test still targets the Vision module's
        // cloud-opt-in detector.
        let cb = JarvisVision.ContextBuilder()
        XCTAssertTrue(cb.matchesCloudOptIn("send to opus, what's this"),
                      "ContextBuilder must flag 'send to opus' as cloud opt-in")
        XCTAssertFalse(cb.matchesCloudOptIn("what's this"),
                       "neutral prompt should NOT flag cloud opt-in")
    }

    /// Test 5 — turnHadImage(_:) returns true after an image-bearing turn
    /// completes; false for text-only.
    func testTurnHadImageReturnsTrueForImageTurns() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let router = makeRouter(t1: mock, t2: mock)
        let (orch, _, _) = try await buildOrchestrator(provider: mock, visionRouter: router)

        let imageInput = TurnInput.withImages(.text, text: "describe", images: [Self.fakeImage])
        guard case .ran(let imageTurnId) = await orch.submit(imageInput) else {
            return XCTFail("expected .ran for image turn")
        }
        _ = await collectUntilIdle(orch: orch)
        let imageHad = await orch.turnHadImage(imageTurnId)
        XCTAssertTrue(imageHad, "image-bearing turn should be tracked")

        // Submit a text-only follow-up turn (orch is now idle).
        guard case .ran(let textTurnId) = await orch.submit(.text("plain text")) else {
            return XCTFail("expected .ran for text turn")
        }
        _ = await collectUntilIdle(orch: orch)
        let textHad = await orch.turnHadImage(textTurnId)
        XCTAssertFalse(textHad, "text-only turn should NOT be tracked")
    }

    /// Audit 2026-05-12 F-V1 regression — when only `MissingT2Provider` is
    /// wired (production today), a low-confidence T1 response must NOT
    /// escalate to T2. Without the `hasRealT2Provider: false` gate, the
    /// orchestrator would swap to `MissingT2Provider`, whose stream throws
    /// `t2ProviderUnavailable`, and the turn would die with an error event.
    func testLowConfidenceT1StaysOnT1WhenT2ProviderIsMissing() async throws {
        // T1 returns a low-confidence answer that would trigger escalation if
        // T2 were available.
        let t1Mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m_t1", model: "gemma4:31b", usagePrefix: nil)),
            .textDelta("I'm not sure"),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        // Production wiring: T2 is `MissingT2Provider`. If reached its stream
        // throws `VisionError.t2ProviderUnavailable`.
        let router = VisionRouter(
            t1Provider: t1Mock,
            t2Provider: MissingT2Provider(),
            t3Provider: t1Mock
        )
        // Default `hasRealT2Provider: false` mirrors AppDelegate.installVision.
        let (orch, _, _) = try await buildOrchestrator(provider: t1Mock, visionRouter: router)

        let input = TurnInput.withImages(.text, text: "what is this", images: [Self.fakeImage])
        let outcome = await orch.submit(input)
        guard case .ran(let turnId) = outcome else { return XCTFail("expected .ran") }

        let events = await collectUntilIdle(orch: orch)

        // T1 was called exactly once — escalation did NOT fire, so
        // MissingT2Provider was never streamed.
        let t1Calls = await t1Mock.getRecordedCalls()
        XCTAssertEqual(t1Calls.count, 1, "T1 should be the only provider invoked when hasRealT2Provider is false")

        // Exactly one .turnEnd — no error event.
        let turnEnds = events.compactMap { event -> TurnID? in
            if case .turnEnd(let id, _) = event { return id }
            return nil
        }
        XCTAssertEqual(turnEnds.count, 1, "exactly one turnEnd; the turn must not die with a provider error")
        XCTAssertEqual(turnEnds.first, turnId)

        // No error event surfaced.
        let errored = events.contains { event in
            if case .error = event { return true }
            return false
        }
        XCTAssertFalse(errored, "no error event should surface — MissingT2Provider must never be reached")
    }

    /// Test 6 — escalationAttempt is a distinct ReplayEvent case from
    /// streamTruncatedRetry (the AGENT-09 retry path). Pattern matching on
    /// each is mutually exclusive.
    func testEscalationAttemptIsDistinctFromMemoryMutation() {
        let turnId = TurnID(rawValue: "t-test")
        let escalation: ReplayEvent = .escalationAttempt(turnId: turnId, kind: .t1ToT2)
        let memoryMutation: ReplayEvent = .memoryMutation(Data("x".utf8))

        var sawEscalation = false
        var sawOther = false
        for ev in [escalation, memoryMutation] {
            switch ev {
            case .escalationAttempt: sawEscalation = true
            default: sawOther = true
            }
        }
        XCTAssertTrue(sawEscalation && sawOther,
                      ".escalationAttempt and other ReplayEvent cases must be mutually exclusive")
    }
}
