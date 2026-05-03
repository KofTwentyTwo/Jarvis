import XCTest
import AgentCore
@testable import AgentOrchestrator

/// Phase 9 / Plan 1 — D-05/06/07/08 invariants codified.
///
/// Each test exercises a single decision:
/// - testFanOutDeliversToAllSubscribers           — D-05 fan-out semantics.
/// - testDropOldestOnTokenDeltaSaturation         — D-06 drop-oldest policy.
/// - testMemoryPriorityProtectsTurnEnd            — D-07 priority filter.
/// - testStuckConsumerDoesNotBlockOthers          — D-06 isolation.
/// - testStopCancelsDrainTask                     — D-08 lifecycle.
/// - testIsProtectedForPriorityMatrix             — D-07 protection table.
final class OrchestratorEventBroadcasterTests: XCTestCase {

    // MARK: - Helpers

    private func makeUpstream() -> BoundedAsyncChannel<OrchestratorEvent> {
        BoundedAsyncChannel<OrchestratorEvent>(capacity: 256, policy: .suspend)
    }

    private func turn(_ id: String) -> TurnID { TurnID(rawValue: id) }

    /// Drain up to `count` events from a subscriber's stream, with a hard
    /// timeout so a missing/blocked event doesn't hang the test indefinitely.
    /// `nonisolated` so concurrent `async let` calls don't trip Swift 6's
    /// task-isolation sender check.
    private nonisolated static func collect(
        stream: AsyncStream<OrchestratorEvent>,
        count: Int,
        timeout: TimeInterval
    ) async -> [OrchestratorEvent] {
        let collectTask = Task<[OrchestratorEvent], Never> {
            var local: [OrchestratorEvent] = []
            for await event in stream {
                local.append(event)
                if local.count >= count { break }
            }
            return local
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collectTask.cancel()
        }
        let result = await collectTask.value
        timeoutTask.cancel()
        return result
    }

    // MARK: - Test 1: D-05 fan-out

    func testFanOutDeliversToAllSubscribers() async throws {
        let upstream = makeUpstream()
        let broadcaster = OrchestratorEventBroadcaster(upstream: upstream)
        await broadcaster.start()

        let memSub = await broadcaster.subscribe(priority: .memory, capacity: 16)
        let devSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 16)
        let frameSub = await broadcaster.subscribe(priority: .frameAttach, capacity: 16)

        // Send a deterministic 5-event sequence upstream.
        let events: [OrchestratorEvent] = [
            .stateChange(.thinking),
            .tokenDelta(turnId: turn("t1"), text: "hello"),
            .tokenDelta(turnId: turn("t1"), text: " world"),
            .turnEnd(turnId: turn("t1"), stopReason: .endTurn),
            .stateChange(.idle),
        ]
        for e in events { await upstream.send(e) }

        async let memCollected = Self.collect(stream: memSub.stream, count: 5, timeout: 2.0)
        async let devCollected = Self.collect(stream: devSub.stream, count: 5, timeout: 2.0)
        async let frameCollected = Self.collect(stream: frameSub.stream, count: 5, timeout: 2.0)

        let (m, d, f) = await (memCollected, devCollected, frameCollected)

        XCTAssertEqual(m.count, 5, "memory subscriber missed events")
        XCTAssertEqual(d.count, 5, "devOverlay subscriber missed events")
        XCTAssertEqual(f.count, 5, "frameAttach subscriber missed events")

        // Order is preserved across all subscribers.
        for collected in [m, d, f] {
            for (i, expected) in events.enumerated() {
                guard i < collected.count else { break }
                XCTAssertEqual(
                    eventDiscriminator(collected[i]),
                    eventDiscriminator(expected),
                    "subscriber out of order at index \(i)"
                )
            }
        }

        await broadcaster.stop()
    }

    // MARK: - Test 2: D-06 drop-oldest on lossy class

    func testDropOldestOnTokenDeltaSaturation() async throws {
        let upstream = makeUpstream()
        let broadcaster = OrchestratorEventBroadcaster(upstream: upstream)
        await broadcaster.start()

        // devOverlay capacity 2; everything is lossy for this priority.
        let devSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 2)

        // Five tokenDeltas; oldest 3 should be dropped from the internal mirror.
        for i in 0..<5 {
            await upstream.send(.tokenDelta(turnId: turn("t1"), text: "tok\(i)"))
        }

        // Wait for fan-out to drain — busy-wait poll the broadcaster's mirror.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await broadcaster.bufferCount(for: devSub.id) == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let count = await broadcaster.bufferCount(for: devSub.id)
        XCTAssertEqual(count, 2, "devOverlay buffer should hold last 2 tokenDelta events")

        await broadcaster.stop()
    }

    // MARK: - Test 3: D-07 memory priority protects .turnEnd

    func testMemoryPriorityProtectsTurnEnd() async throws {
        let upstream = makeUpstream()
        let broadcaster = OrchestratorEventBroadcaster(upstream: upstream)
        await broadcaster.start()

        let memSub = await broadcaster.subscribe(priority: .memory, capacity: 2)

        // Saturate with 2 lossy tokenDeltas.
        await upstream.send(.tokenDelta(turnId: turn("t1"), text: "a"))
        await upstream.send(.tokenDelta(turnId: turn("t1"), text: "b"))
        // Push a third tokenDelta — oldest dropped from the internal mirror.
        await upstream.send(.tokenDelta(turnId: turn("t1"), text: "c"))
        // Now send a protected event — must be appended even though mirror at cap.
        await upstream.send(.turnEnd(turnId: turn("t1"), stopReason: .endTurn))

        // Drain 4 events — every event yielded reaches the consumer's stream
        // (the unbounded continuation buffer absorbs them); the drop-oldest
        // policy gates only the internal mirror that tracks per-consumer
        // capacity for the priority filter. The protection invariant under
        // test: .turnEnd MUST be among the yielded events even when the
        // memory consumer's mirror was already at capacity.
        let events = await Self.collect(stream: memSub.stream, count: 4, timeout: 2.0)

        XCTAssertEqual(events.count, 4, "memory subscriber must receive turnEnd in addition to deltas")
        if let last = events.last {
            if case .turnEnd = last {} else {
                XCTFail("expected last event to be .turnEnd, got \(last)")
            }
        } else {
            XCTFail("no events received")
        }

        await broadcaster.stop()
    }

    // MARK: - Test 4: D-06 stuck consumer isolation

    func testStuckConsumerDoesNotBlockOthers() async throws {
        let upstream = makeUpstream()
        let broadcaster = OrchestratorEventBroadcaster(upstream: upstream)
        await broadcaster.start()

        // memory subscriber drains; devOverlay subscriber NEVER drains its stream.
        // (Hold onto the Subscription so the continuation isn't deinit'd.)
        let memSub = await broadcaster.subscribe(priority: .memory, capacity: 256)
        let stuckSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 16)
        _ = stuckSub  // explicitly retain; never iterate.

        // Send 100 turnEnds (protected for memory; lossy for devOverlay).
        for i in 0..<100 {
            await upstream.send(.turnEnd(turnId: turn("t\(i)"), stopReason: .endTurn))
        }

        // Memory subscriber MUST receive all 100 even though devOverlay is stuck.
        let events = await Self.collect(stream: memSub.stream, count: 100, timeout: 3.0)

        XCTAssertEqual(events.count, 100, "memory subscriber blocked by stuck devOverlay subscriber")

        await broadcaster.stop()
    }

    // MARK: - Test 5: D-08 stop() cancels drain Task

    func testStopCancelsDrainTask() async throws {
        let upstream = makeUpstream()
        let broadcaster = OrchestratorEventBroadcaster(upstream: upstream)
        await broadcaster.start()

        let sub = await broadcaster.subscribe(priority: .memory, capacity: 16)

        await upstream.send(.stateChange(.thinking))
        let first = await Self.collect(stream: sub.stream, count: 1, timeout: 2.0)
        XCTAssertEqual(first.count, 1)

        // Stop the broadcaster — subscriber stream MUST terminate.
        await broadcaster.stop()

        // After stop, iterating the (already-finished) stream returns nothing.
        // (collect() returns whatever's already buffered, then the stream ends.)
        var trailing: [OrchestratorEvent] = []
        for await event in sub.stream {
            trailing.append(event)
            if trailing.count > 10 { break }  // safety
        }
        XCTAssertEqual(trailing.count, 0, "subscriber stream should end after broadcaster.stop()")

        // Subsequent upstream sends MUST NOT reach a re-fanned-out path.
        await upstream.send(.stateChange(.idle))
        // No assertion possible beyond "no crash"; the drain Task is cancelled.
    }

    // MARK: - Test 6: D-07 protection matrix table-driven

    func testIsProtectedForPriorityMatrix() async throws {
        let broadcaster = OrchestratorEventBroadcaster(upstream: makeUpstream())

        let id = turn("t1")
        let cardUpdate = ToolCardUpdate(
            turnId: id,
            toolUseId: "u1",
            toolName: "tool",
            phase: .running,
            resultPreview: nil,
            error: nil
        )
        let usage = TurnUsage(
            inputTokens: 0, outputTokens: 0,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0
        )

        let allEvents: [(label: String, event: OrchestratorEvent)] = [
            ("stateChange", .stateChange(.thinking)),
            ("tokenDelta", .tokenDelta(turnId: id, text: "x")),
            ("thinkingDelta", .thinkingDelta(turnId: id, text: "y")),
            ("toolCardUpdate", .toolCardUpdate(cardUpdate)),
            ("usage", .usage(turnId: id, usage: usage)),
            ("turnEnd", .turnEnd(turnId: id, stopReason: .endTurn)),
            ("error", .error(turnId: id, error: .transport(description: "boom"))),
        ]

        // memory: protects everything except tokenDelta + thinkingDelta.
        for (label, event) in allEvents {
            let isProtected = await broadcaster.isProtectedForPriority(event, priority: .memory)
            let lossy = (label == "tokenDelta" || label == "thinkingDelta")
            XCTAssertEqual(
                isProtected, !lossy,
                ".memory priority protection wrong for \(label)"
            )
        }

        // transcript: same rules as memory.
        for (label, event) in allEvents {
            let isProtected = await broadcaster.isProtectedForPriority(event, priority: .transcript)
            let lossy = (label == "tokenDelta" || label == "thinkingDelta")
            XCTAssertEqual(
                isProtected, !lossy,
                ".transcript priority protection wrong for \(label)"
            )
        }

        // devOverlay: protects nothing.
        for (label, event) in allEvents {
            let isProtected = await broadcaster.isProtectedForPriority(event, priority: .devOverlay)
            XCTAssertFalse(isProtected, ".devOverlay should treat \(label) as lossy")
        }

        // frameAttach: protects ONLY .turnEnd.
        for (label, event) in allEvents {
            let isProtected = await broadcaster.isProtectedForPriority(event, priority: .frameAttach)
            XCTAssertEqual(
                isProtected, label == "turnEnd",
                ".frameAttach should protect only turnEnd, mismatch on \(label)"
            )
        }

        // voice: protects .turnEnd + .error.
        for (label, event) in allEvents {
            let isProtected = await broadcaster.isProtectedForPriority(event, priority: .voice)
            let expected = (label == "turnEnd" || label == "error")
            XCTAssertEqual(
                isProtected, expected,
                ".voice priority protection wrong for \(label)"
            )
        }

        // bus: same rules as memory/transcript — only tokenDelta /
        // thinkingDelta are drop-eligible. Phase E (BLOCKER-INT-2) added
        // this priority so AppDelegate has a canonical bus-forwarding sub.
        for (label, event) in allEvents {
            let isProtected = await broadcaster.isProtectedForPriority(event, priority: .bus)
            let lossy = (label == "tokenDelta" || label == "thinkingDelta")
            XCTAssertEqual(
                isProtected, !lossy,
                ".bus priority protection wrong for \(label)"
            )
        }
    }

    // MARK: - Helpers

    /// Returns a stable string discriminator for an OrchestratorEvent so tests
    /// can compare event-class equality without forcing `Equatable` on the enum.
    private func eventDiscriminator(_ e: OrchestratorEvent) -> String {
        switch e {
        case .stateChange:    return "stateChange"
        case .tokenDelta:     return "tokenDelta"
        case .thinkingDelta:  return "thinkingDelta"
        case .toolCardUpdate: return "toolCardUpdate"
        case .usage:          return "usage"
        case .turnEnd:        return "turnEnd"
        case .error:          return "error"
        }
    }
}
