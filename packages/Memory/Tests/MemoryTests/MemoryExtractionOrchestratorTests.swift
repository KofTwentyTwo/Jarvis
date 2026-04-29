import XCTest
import Foundation
import AgentCore
import AgentOrchestrator
import Replay
@testable import Memory

/// Plan 07-02 Task 4: MemoryExtractionOrchestrator (bounded channel +
/// serial drain) + MemoryExtractionCoordinator (turnEnd subscriber,
/// non-blocking).
///
/// Most tests use mock collaborators because constructing a real
/// `MemoryStore` requires `vec0.dylib` (env-gated). The orchestrator's
/// test seam (init takes any-LLMProvider extractor + a callback for
/// applyOp) lets us drive D-01/MEM-06 invariants without touching
/// SQLite.
final class MemoryExtractionOrchestratorTests: XCTestCase {

    // MARK: - Mock collaborators

    /// Mock extractor that mirrors the real MemoryExtractor's public API
    /// shape (extract(...) -> [MemoryOp]) but does not call an LLMProvider.
    /// We construct it via a private `MemoryExtractor` initialized with
    /// a MockLLMProvider — but to control timing precisely we instead
    /// provide a TimedExtractorBox that the orchestrator can call directly.
    /// The simplest way to do this without bloating the API: drive the real
    /// MemoryExtractor through a controllable mock provider.
    final class TimedMockProvider: LLMProvider, @unchecked Sendable {
        let lock = NSLock()
        var sleepNs: UInt64 = 0
        var throwError: Error?
        /// Pre-encoded apply_memory_ops argsJSON. Empty Data → no tool call.
        var argsJSON: Data = Data()

        // Records start/end so tests can assert serial drain.
        nonisolated(unsafe) static var calls: [(start: Date, end: Date)] = []
        nonisolated(unsafe) static var callsLock = NSLock()

        static func resetCalls() {
            callsLock.lock(); defer { callsLock.unlock() }
            calls = []
        }
        static func snapshot() -> [(start: Date, end: Date)] {
            callsLock.lock(); defer { callsLock.unlock() }
            return calls
        }
        /// Sync helper safe to call from async contexts (NSLock isn't, but a
        /// non-async wrapper that does the lock + mutate + unlock is).
        nonisolated static func appendCall(start: Date, end: Date) {
            callsLock.lock(); defer { callsLock.unlock() }
            calls.append((start, end))
        }

        nonisolated func flipToPassing(argsJSON: Data) {
            lock.lock(); defer { lock.unlock() }
            self.throwError = nil
            self.argsJSON = argsJSON
        }

        func stream(
            messages: [LLMMessage],
            tools: [ToolSchema],
            toolChoice: ToolChoice,
            model: ModelID,
            maxOutputTokens: Int,
            cacheHints: CacheHints?
        ) -> AsyncThrowingStream<LLMEvent, Error> {
            lock.lock()
            let s = sleepNs
            let err = throwError
            let args = self.argsJSON
            lock.unlock()

            return AsyncThrowingStream { continuation in
                Task {
                    let start = Date()
                    if s > 0 {
                        try? await Task.sleep(nanoseconds: s)
                    }
                    let end = Date()
                    Self.appendCall(start: start, end: end)

                    if let err = err {
                        continuation.finish(throwing: err)
                        return
                    }
                    if !args.isEmpty {
                        continuation.yield(.toolUseRequested(
                            ToolUseRequest(id: "t1", name: "apply_memory_ops", argsJSON: args)
                        ))
                    }
                    continuation.yield(.messageStop)
                    continuation.finish()
                }
            }
        }
    }

    /// Spy MemoryStore-shaped sink: counts applyOp invocations.
    /// We can't construct a real MemoryStore without vec0.dylib.
    /// MemoryExtractionOrchestrator must accept an injectable applyOp
    /// callback (test seam) for non-DB tests to assert reach-through.
    final class SpyApplyOp: @unchecked Sendable {
        let lock = NSLock()
        nonisolated(unsafe) private var _calls: [(op: MemoryOp, sourceTurnId: Int64)] = []
        var calls: [(op: MemoryOp, sourceTurnId: Int64)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ op: MemoryOp, sourceTurnId: Int64) {
            lock.lock(); defer { lock.unlock() }
            _calls.append((op, sourceTurnId))
        }
    }

    // MARK: - Tests

    /// MEM-06 non-blocking: 100 enqueues against a stalled extractor
    /// must complete in well under 500 ms. The dropOldest policy absorbs
    /// overflow without ever suspending the producer.
    func testEnqueueDoesNotBlockUnderOverflow() async throws {
        let provider = TimedMockProvider()
        provider.sleepNs = UInt64(60_000_000_000) // 60 s
        let extractor = MemoryExtractor(provider: provider)
        let spy = SpyApplyOp()
        let orchestrator = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in spy.record(op, sourceTurnId: turnId) }
        )
        await orchestrator.start()

        let start = Date()
        for i in 0..<100 {
            await orchestrator.enqueue(ExtractionJob(
                turnId: TurnID(rawValue: "turn-\(i)"),
                userText: "u\(i)",
                assistantText: "a\(i)"
            ))
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5,
                          "MEM-06 non-blocking: 100 enqueues must complete in well under 500ms regardless of extractor latency. Got \(elapsed)s")

        await orchestrator.shutdown()
    }

    /// RESEARCH §7: serial drain — never two extract() calls in flight at once.
    func testDrainTaskIsSerial() async throws {
        TimedMockProvider.resetCalls()
        let provider = TimedMockProvider()
        provider.sleepNs = UInt64(50_000_000) // 50 ms per call

        let extractor = MemoryExtractor(provider: provider)
        let spy = SpyApplyOp()
        let orchestrator = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in spy.record(op, sourceTurnId: turnId) }
        )
        await orchestrator.start()

        for i in 0..<5 {
            await orchestrator.enqueue(ExtractionJob(
                turnId: TurnID(rawValue: "turn-\(i)"),
                userText: "u\(i)",
                assistantText: "a\(i)"
            ))
        }

        // Wait long enough for all 5 to drain serially: 5 * 50 ms + slack.
        try await Task.sleep(nanoseconds: 800_000_000)

        let snap = TimedMockProvider.snapshot().sorted { $0.start < $1.start }
        XCTAssertEqual(snap.count, 5,
                       "Expected all 5 jobs to drain. Saw \(snap.count) calls.")
        for i in 1..<snap.count {
            XCTAssertGreaterThanOrEqual(snap[i].start, snap[i-1].end,
                                        "Drain must be serial: call \(i) started before call \(i-1) ended.")
        }
        await orchestrator.shutdown()
    }

    /// Process applies returned ops to the store via the callback.
    func testProcessAppliesOpsToStore() async throws {
        let provider = TimedMockProvider()
        provider.argsJSON = try JSONSerialization.data(withJSONObject: ["ops": [
            ["op": "ADD", "subject": "Sarah", "predicate": "works_at", "object": "Acme"]
        ]])
        let extractor = MemoryExtractor(provider: provider)
        let spy = SpyApplyOp()
        let orchestrator = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in spy.record(op, sourceTurnId: turnId) }
        )
        await orchestrator.start()

        await orchestrator.enqueue(ExtractionJob(
            turnId: TurnID(rawValue: "turn-1"),
            userText: "Sarah works at Acme.",
            assistantText: "Got it."
        ))

        // wait for drain
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spy.calls.count, 1)
        guard case .add(let s, _, let o, _) = spy.calls.first?.op else {
            return XCTFail("expected applyOp(.add)")
        }
        XCTAssertEqual(s, "Sarah")
        XCTAssertEqual(o, "Acme")

        await orchestrator.shutdown()
    }

    /// Extractor errors must NOT kill the drain task.
    func testProcessNeverThrowsToProducer() async throws {
        struct DummyError: Error {}
        let provider = TimedMockProvider()
        provider.throwError = DummyError()

        let extractor = MemoryExtractor(provider: provider)
        let spy = SpyApplyOp()
        let orchestrator = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in spy.record(op, sourceTurnId: turnId) }
        )
        await orchestrator.start()

        // Three failing jobs.
        for i in 0..<3 {
            await orchestrator.enqueue(ExtractionJob(
                turnId: TurnID(rawValue: "fail-\(i)"),
                userText: "u\(i)", assistantText: "a\(i)"
            ))
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        // Now flip the provider to passing, enqueue a fourth, assert it processes.
        let okArgs = try JSONSerialization.data(withJSONObject: ["ops": [
            ["op": "ADD", "subject": "X", "predicate": "Y", "object": "Z"]
        ]])
        provider.flipToPassing(argsJSON: okArgs)

        await orchestrator.enqueue(ExtractionJob(
            turnId: TurnID(rawValue: "ok-1"),
            userText: "u4", assistantText: "a4"
        ))
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(spy.calls.count, 1, "Drain task survived prior errors and processed the new job.")
        await orchestrator.shutdown()
    }

    // MARK: - Coordinator tests

    /// Successful turn (.endTurn) → enqueue.
    func testCoordinatorEnqueuesOnTurnEndWithEndTurn() async throws {
        let provider = TimedMockProvider()
        let extractor = MemoryExtractor(provider: provider)
        let spy = SpyApplyOp()
        let memOrch = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in spy.record(op, sourceTurnId: turnId) }
        )

        let events = BoundedAsyncChannel<OrchestratorEvent>(capacity: 16, policy: .suspend)
        let captured = JobCapture()
        let coord = MemoryExtractionCoordinator(memoryOrchestrator: memOrch)

        await coord.start(orchestratorEvents: events) { _ in
            captured.markFetch()
            return ("the user said x", "the assistant said y")
        }

        // Override enqueue path — give the test a way to observe the
        // orchestrator's enqueue input. Easiest is to wrap our own
        // orchestrator-shaped sink on top of memOrch by reading `spy.calls`
        // after a tick.
        let turnId = TurnID(rawValue: "turn-77")
        await events.send(.turnEnd(turnId: turnId, stopReason: .endTurn))
        await events.finish()
        // wait for processing
        try await Task.sleep(nanoseconds: 250_000_000)
        await memOrch.start()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertGreaterThanOrEqual(captured.fetchCount, 1,
                                    "Coordinator must call turnContent for an .endTurn event.")
        await coord.stop()
        await memOrch.shutdown()
    }

    /// Refusal / max-tokens turns are dropped (no enqueue).
    func testCoordinatorIgnoresTurnEndWithRefusalOrMaxTokens() async throws {
        let provider = TimedMockProvider()
        let extractor = MemoryExtractor(provider: provider)
        let spy = SpyApplyOp()
        let memOrch = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in spy.record(op, sourceTurnId: turnId) }
        )

        let events = BoundedAsyncChannel<OrchestratorEvent>(capacity: 16, policy: .suspend)
        let captured = JobCapture()
        let coord = MemoryExtractionCoordinator(memoryOrchestrator: memOrch)

        await coord.start(orchestratorEvents: events) { _ in
            captured.markFetch()
            return ("u", "a")
        }

        await events.send(.turnEnd(turnId: TurnID(rawValue: "tA"), stopReason: .refusal))
        await events.send(.turnEnd(turnId: TurnID(rawValue: "tB"), stopReason: .maxTokens))
        await events.send(.turnEnd(turnId: TurnID(rawValue: "tC"), stopReason: .toolUse))
        await events.finish()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(captured.fetchCount, 0,
                       "Coordinator must NOT enqueue for non-endTurn stops.")
        await coord.stop()
        await memOrch.shutdown()
    }

    /// turnContent closure receives the matching turnId.
    func testCoordinatorReadsUserAssistantViaCallback() async throws {
        let provider = TimedMockProvider()
        let extractor = MemoryExtractor(provider: provider)
        let spy = SpyApplyOp()
        let memOrch = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in spy.record(op, sourceTurnId: turnId) }
        )

        let events = BoundedAsyncChannel<OrchestratorEvent>(capacity: 16, policy: .suspend)
        let captured = JobCapture()
        let coord = MemoryExtractionCoordinator(memoryOrchestrator: memOrch)

        await coord.start(orchestratorEvents: events) { id in
            captured.lastTurnId = id
            return ("u", "a")
        }

        await events.send(.turnEnd(turnId: TurnID(rawValue: "match-me"), stopReason: .endTurn))
        await events.finish()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(captured.lastTurnId?.rawValue, "match-me")
        await coord.stop()
        await memOrch.shutdown()
    }

    /// stop() cancels the subscription Task — no further events are processed.
    func testCoordinatorStopCancelsTask() async throws {
        let provider = TimedMockProvider()
        let extractor = MemoryExtractor(provider: provider)
        let spy = SpyApplyOp()
        let memOrch = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in spy.record(op, sourceTurnId: turnId) }
        )

        let events = BoundedAsyncChannel<OrchestratorEvent>(capacity: 16, policy: .suspend)
        let captured = JobCapture()
        let coord = MemoryExtractionCoordinator(memoryOrchestrator: memOrch)

        await coord.start(orchestratorEvents: events) { _ in
            captured.markFetch()
            return ("u", "a")
        }

        await coord.stop()
        // Send an event AFTER stop — turnContent must not be called again.
        let initial = captured.fetchCount
        await events.send(.turnEnd(turnId: TurnID(rawValue: "post-stop"), stopReason: .endTurn))
        await events.finish()
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(captured.fetchCount, initial,
                       "Post-stop events must not invoke turnContent.")
        await memOrch.shutdown()
    }

    // MARK: - shared capture

    final class JobCapture: @unchecked Sendable {
        let lock = NSLock()
        nonisolated(unsafe) private var _fetchCount: Int = 0
        nonisolated(unsafe) var lastTurnId: TurnID?

        var fetchCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _fetchCount
        }
        func markFetch() {
            lock.lock(); defer { lock.unlock() }
            _fetchCount += 1
        }
    }
}
