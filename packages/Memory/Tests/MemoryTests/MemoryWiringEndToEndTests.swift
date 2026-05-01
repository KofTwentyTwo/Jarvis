import XCTest
import Foundation
import AgentCore
import AgentOrchestrator
@testable import Memory

/// Phase 9 / Plan 1 — BLOCKER-1 end-to-end verification.
///
/// Drives a real `OrchestratorEventBroadcaster` + real `TurnTranscriptStore`
/// + real `MemoryExtractionCoordinator` wired to a job-capturing spy.
/// Asserts the spy's `enqueue` receives a NON-NIL `userText` AND
/// `assistantText` — the regression mode that BLOCKER-1 closes.
///
/// **What this protects against:** the Phase 7-era nil-stub
/// `agentOrchestratorEvents()` made `lookupTurnContent` always return
/// nil; `MemoryExtractionCoordinator`'s drain logged "turnContent
/// returned nil" and skipped extraction. With the broadcaster +
/// transcript store wiring, the closure returns the accumulated
/// (userText, assistantText) pair so memory extraction actually runs
/// in production.
final class MemoryWiringEndToEndTests: XCTestCase {

    /// Test-only spy capturing each enqueued job in order.
    actor JobSpy: MemoryEnqueueing {
        var enqueued: [ExtractionJob] = []
        func enqueue(_ job: ExtractionJob) async {
            enqueued.append(job)
        }
        func count() -> Int { enqueued.count }
        func first() -> ExtractionJob? { enqueued.first }
    }

    func testMemoryEnqueueReceivesNonNilUserAndAssistantText() async throws {
        // 1. TurnTranscriptStore — Plan 4 will append user side at submit-time.
        //    Plan 1 simulates that single user-side append here.
        let store = TurnTranscriptStore()
        let testTurnId = TurnID(rawValue: "end-to-end-1")
        await store.append(turnId: testTurnId, role: .user, deltaText: "hi")

        // 2. Job-capturing spy in place of the real MemoryExtractionOrchestrator.
        let spy = JobSpy()
        let coord = MemoryExtractionCoordinator(memoryOrchestrator: spy)

        // 3. Real broadcaster around an upstream channel matching production
        //    wiring (capacity 256, suspend policy = AgentOrchestrator default).
        let upstream = BoundedAsyncChannel<OrchestratorEvent>(capacity: 256, policy: .suspend)
        let broadcaster = OrchestratorEventBroadcaster(upstream: upstream)
        await broadcaster.start()

        // 4. Memory + transcript subscribers — exactly mirroring installAgent's wiring.
        let memorySub = await broadcaster.subscribe(priority: .memory, capacity: 256)
        let transcriptSub = await broadcaster.subscribe(priority: .transcript, capacity: 256)

        await coord.start(orchestratorEvents: memorySub.stream) { turnId in
            await store.flushPair(turnId).map { pair in
                (user: pair.userText, assistant: pair.assistantText)
            }
        }

        let transcriptTask = Task {
            for await event in transcriptSub.stream {
                if case let .tokenDelta(turnId, text) = event {
                    await store.append(turnId: turnId, role: .assistant, deltaText: text)
                }
            }
        }

        // 5. Drive a deterministic transcript through the upstream channel.
        await upstream.send(.tokenDelta(turnId: testTurnId, text: "hello "))
        await upstream.send(.tokenDelta(turnId: testTurnId, text: "there"))
        await upstream.send(.turnEnd(turnId: testTurnId, stopReason: .endTurn))

        // 6. Wait for the memory subscriber to drain + enqueue. The transcript
        //    subscriber needs a moment to append both deltas before the memory
        //    subscriber's drain processes .turnEnd; broadcaster fan-out is
        //    synchronous per event so the transcript task wins the race for
        //    each .tokenDelta before .turnEnd reaches memory's drain.
        let deadline = Date().addingTimeInterval(2.0)
        while await spy.count() == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // 7. Assert: enqueue called once with the EXPECTED non-nil pair.
        let count = await spy.count()
        XCTAssertEqual(count, 1, "enqueue was not called — BLOCKER-1 regression")
        let job = await spy.first()
        XCTAssertNotNil(job)
        XCTAssertEqual(job?.userText, "hi",
            "userText empty/nil — Plan 4's submit-time append did not propagate via TurnTranscriptStore")
        XCTAssertEqual(job?.assistantText, "hello there",
            "assistantText empty/nil — Plan 1's transcript subscriber did not propagate via TurnTranscriptStore")

        // 8. Cleanup.
        transcriptTask.cancel()
        await coord.stop()
        await broadcaster.stop()
    }
}
