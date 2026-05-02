import XCTest
import AgentCore
import Config
import Replay
import JarvisVision
@testable import AgentOrchestrator

/// Plan 09-03 / D-13 + D-14 — proves AgentOrchestrator.runTurn appends
/// PresenceStateSnapshot.currentEnrichment() to the system prompt during
/// the system-prompt composition step (after UntrustedWrapper.composeSystemPrompt
/// so the enrichment lives OUTSIDE the nonce-wrapped untrusted region per
/// SEC-06).
///
/// VISION-03 boundary: tests only assert on `String?` content of the
/// system message — no presence type leaks to the orchestrator surface.
@MainActor
final class AgentOrchestratorPresenceEnrichmentTests: XCTestCase {

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

    private func makeMock() -> MockLLMProvider {
        MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
            .textDelta("ok"),
            .stopReason(.endTurn),
            .messageStop,
        ]))
    }

    private func buildOrchestrator(
        provider mock: any LLMProvider,
        presenceSnapshot: PresenceStateSnapshot?
    ) async throws -> AgentOrchestrator {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        return AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: [],
            visionRouter: nil,
            presenceSnapshot: presenceSnapshot
        )
    }

    private func collectUntilIdle(orch: AgentOrchestrator, timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        for await event in orch.events {
            if case .stateChange(.idle) = event { return }
            if Date() > deadline { return }
        }
    }

    /// Extract the system message text from the first recorded provider call.
    private func systemPromptOf(_ recordedCalls: [MockLLMProvider.RecordedCall]) -> String? {
        guard let firstCall = recordedCalls.first else { return nil }
        guard let systemMsg = firstCall.messages.first else { return nil }
        guard case .text(let str) = systemMsg.content.first else { return nil }
        return str
    }

    // MARK: - Tests

    /// Test 1 — no presenceSnapshot → system prompt is NOT enriched.
    func testRunTurnWithoutPresenceSnapshotProducesUnenriched() async throws {
        let mock = makeMock()
        let orch = try await buildOrchestrator(provider: mock, presenceSnapshot: nil)

        let outcome = await orch.submit(.text("hello"))
        guard case .ran = outcome else { return XCTFail("expected .ran") }
        await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        let sys = systemPromptOf(calls) ?? ""
        XCTAssertFalse(sys.contains("User is at the desk"),
                       "no snapshot → no presence enrichment")
        XCTAssertFalse(sys.contains("User has been away"),
                       "no snapshot → no presence enrichment")
    }

    /// Test 2 — present + observation ≥ 5s → "User is at the desk." appended.
    func testRunTurnWithPresentSnapshotAppendsSentence() async throws {
        let mock = makeMock()
        let snap = PresenceStateSnapshot()
        // Record a present transition with a wall-clock observation in the
        // past. PresenceStateSnapshot.record uses Date() for observedAt, so
        // we use a small sleep below to push the observation past the 5s
        // suppression window — except that's too slow; instead we record
        // .absentLongTerm (no suppression) for a deterministic check. To
        // keep this test on the .present branch, we sleep 5.05 seconds.
        // Since CI may flake, we use absentLongTerm in test 4 and gate this
        // test behind a "since" that still fits the suppression rule check.
        //
        // Approach: record .present, then read currentEnrichment with a
        // forced future `now` directly from the snapshot to verify behavior;
        // but the orchestrator path calls currentEnrichment() with default
        // `now = Date()`. So we must wait ≥5 seconds.
        await snap.record(.transition(to: .present, at: Date(), debounced: 2.0))
        try await Task.sleep(nanoseconds: 5_100_000_000)  // 5.1 s

        let orch = try await buildOrchestrator(provider: mock, presenceSnapshot: snap)
        let outcome = await orch.submit(.text("hello"))
        guard case .ran = outcome else { return XCTFail("expected .ran") }
        await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        let sys = systemPromptOf(calls) ?? ""
        XCTAssertTrue(sys.hasSuffix("\n\nUser is at the desk."),
                      "present snapshot must append plain sentence as suffix; got: \(sys)")
    }

    /// Test 3 — present within 5-second suppression window → unenriched.
    func testRunTurnWithSuppressedSnapshotProducesUnenriched() async throws {
        let mock = makeMock()
        let snap = PresenceStateSnapshot()
        await snap.record(.transition(to: .present, at: Date(), debounced: 2.0))
        // Do not wait — recent observation triggers D-14 suppression.

        let orch = try await buildOrchestrator(provider: mock, presenceSnapshot: snap)
        let outcome = await orch.submit(.text("hello"))
        guard case .ran = outcome else { return XCTFail("expected .ran") }
        await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        let sys = systemPromptOf(calls) ?? ""
        XCTAssertFalse(sys.contains("User is at the desk"),
                       "present + last-seen <5s must suppress enrichment (D-14)")
    }

    /// Test 4 — absentLongTerm produces the away sentence with a deterministic
    /// minute count (no real-time wait needed).
    func testRunTurnWithAbsentSnapshotAppendsAwaySentence() async throws {
        let mock = makeMock()
        let snap = PresenceStateSnapshot()
        let sevenMinutesAgo = Date().addingTimeInterval(-7 * 60)
        await snap.record(.transition(to: .absentLongTerm(since: sevenMinutesAgo),
                                      at: sevenMinutesAgo,
                                      debounced: 2.0))

        let orch = try await buildOrchestrator(provider: mock, presenceSnapshot: snap)
        let outcome = await orch.submit(.text("hello"))
        guard case .ran = outcome else { return XCTFail("expected .ran") }
        await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        let sys = systemPromptOf(calls) ?? ""
        // Allow 7..8 minutes to absorb millisecond drift over the call path.
        let acceptable = sys.contains("User has been away from the desk for 7 minutes.")
                      || sys.contains("User has been away from the desk for 8 minutes.")
        XCTAssertTrue(acceptable,
                      "absentLongTerm must append away sentence with elapsed minutes; got: \(sys)")
    }

    /// Test 5 — querying currentEnrichment in runTurn does not mutate the
    /// snapshot. Two consecutive turns observe the same enrichment.
    func testEnrichmentDoesNotMutatePresenceState() async throws {
        let mock = makeMock()
        let snap = PresenceStateSnapshot()
        let tenMinutesAgo = Date().addingTimeInterval(-10 * 60)
        await snap.record(.transition(to: .absentLongTerm(since: tenMinutesAgo),
                                      at: tenMinutesAgo,
                                      debounced: 2.0))

        let orch = try await buildOrchestrator(provider: mock, presenceSnapshot: snap)

        let firstOutcome = await orch.submit(.text("first"))
        guard case .ran = firstOutcome else { return XCTFail("expected .ran") }
        await collectUntilIdle(orch: orch)

        let secondOutcome = await orch.submit(.text("second"))
        guard case .ran = secondOutcome else { return XCTFail("expected .ran") }
        await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        XCTAssertGreaterThanOrEqual(calls.count, 2)
        // Both system prompts should carry the away sentence (snapshot is
        // read-only on the orchestrator side).
        for call in calls {
            guard let sys = call.messages.first.flatMap({
                if case .text(let s) = $0.content.first { return s } else { return nil }
            }) else { continue }
            XCTAssertTrue(sys.contains("User has been away from the desk for"),
                          "snapshot is read-only; both turns should see the same enrichment; got: \(sys)")
        }
    }
}
