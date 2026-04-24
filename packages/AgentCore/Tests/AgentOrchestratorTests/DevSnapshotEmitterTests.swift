import XCTest
import AgentCore
@testable import AgentOrchestrator

final class DevSnapshotEmitterTests: XCTestCase {
    // DE1: `.stateChange(.thinking)` flips the snapshot state.
    func test_DE1_stateChangeThinkingUpdatesSnapshot() async {
        let emitter = DevSnapshotEmitter()
        await emitter.apply(.stateChange(.thinking))
        let snap = await emitter._currentSnapshot()
        XCTAssertEqual(snap.state, .thinking)
    }

    // DE2: A `.usage` event updates input/output token counts.
    func test_DE2_usageUpdatesTokenCounts() async {
        let emitter = DevSnapshotEmitter()
        let turnId = TurnID(rawValue: "t1")
        let usage = TurnUsage(
            inputTokens: 100, outputTokens: 42,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0
        )
        await emitter.apply(.stateChange(.thinking))
        await emitter.apply(.tokenDelta(turnId: turnId, text: "hi"))
        await emitter.apply(.usage(turnId: turnId, usage: usage))
        let snap = await emitter._currentSnapshot()
        XCTAssertEqual(snap.inputTokens, 100)
        XCTAssertEqual(snap.outputTokens, 42)
    }

    // DE3: Cache hit ratio is computed from the usage event.
    func test_DE3_cacheHitPercentageFromUsage() async {
        let emitter = DevSnapshotEmitter()
        let turnId = TurnID(rawValue: "t2")
        let usage = TurnUsage(
            inputTokens: 100, outputTokens: 0,
            cacheCreationInputTokens: 40, cacheReadInputTokens: 60
        )
        await emitter.apply(.usage(turnId: turnId, usage: usage))
        let snap = await emitter._currentSnapshot()
        XCTAssertEqual(snap.cacheReadInputTokens, 60)
        XCTAssertEqual(snap.cacheCreationInputTokens, 40)
        XCTAssertEqual(snap.cacheHitPercentage, 60.0, accuracy: 0.001)
    }

    // DE4: 7 toolCardUpdate events with distinct IDs → toolCalls holds last 5,
    // in FIFO order (oldest dropped).
    func test_DE4_toolCallRingKeepsLast5() async {
        let emitter = DevSnapshotEmitter()
        let turnId = TurnID(rawValue: "t3")
        for i in 1...7 {
            let upd = ToolCardUpdate(
                turnId: turnId,
                toolUseId: "tool\(i)",
                toolName: "name\(i)",
                phase: .completed,
                resultPreview: "preview\(i)",
                error: nil
            )
            await emitter.apply(.toolCardUpdate(upd))
        }
        let snap = await emitter._currentSnapshot()
        XCTAssertEqual(snap.toolCalls.count, 5)
        XCTAssertEqual(snap.toolCalls.map(\.id), ["tool3", "tool4", "tool5", "tool6", "tool7"])
    }

    // DE4b: Repeated updates for the same toolUseId update the existing row
    // rather than pushing new ones. (T-04-05-03 DoS mitigation.)
    func test_DE4b_toolCardUpdateDedupesOnId() async {
        let emitter = DevSnapshotEmitter()
        let turnId = TurnID(rawValue: "t3b")
        let id = "same_tool"
        await emitter.apply(.toolCardUpdate(ToolCardUpdate(
            turnId: turnId, toolUseId: id, toolName: "x",
            phase: .pending, resultPreview: nil, error: nil
        )))
        await emitter.apply(.toolCardUpdate(ToolCardUpdate(
            turnId: turnId, toolUseId: id, toolName: "x",
            phase: .running, resultPreview: nil, error: nil
        )))
        await emitter.apply(.toolCardUpdate(ToolCardUpdate(
            turnId: turnId, toolUseId: id, toolName: "x",
            phase: .completed, resultPreview: "ok", error: nil
        )))
        let snap = await emitter._currentSnapshot()
        XCTAssertEqual(snap.toolCalls.count, 1)
        XCTAssertEqual(snap.toolCalls[0].status, .completed)
        XCTAssertEqual(snap.toolCalls[0].preview, "ok")
    }

    // DE5: TTFB is recorded on the first .tokenDelta after .stateChange(.thinking).
    func test_DE5_ttfbRecordedOnFirstTokenDelta() async {
        let emitter = DevSnapshotEmitter()
        let turnId = TurnID(rawValue: "t4")
        await emitter.apply(.stateChange(.thinking))
        // Sleep enough to produce a non-zero ttfb without making the test flaky.
        try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
        await emitter.apply(.tokenDelta(turnId: turnId, text: "hi"))
        let snap = await emitter._currentSnapshot()
        XCTAssertGreaterThanOrEqual(snap.ttfbMs, 20)
        XCTAssertLessThan(snap.ttfbMs, 500, "TTFB should be small, test ran in ~25ms range")
    }

    // DE6: `.turnEnd` resets state to .idle and records totalMs; a second
    // `.turnEnd` does NOT crash (idempotent).
    func test_DE6_turnEndResetsAndIsIdempotent() async {
        let emitter = DevSnapshotEmitter()
        let turnId = TurnID(rawValue: "t5")
        await emitter.apply(.stateChange(.thinking))
        try? await Task.sleep(nanoseconds: 10_000_000)
        await emitter.apply(.turnEnd(turnId: turnId, stopReason: .endTurn))
        let snap1 = await emitter._currentSnapshot()
        XCTAssertEqual(snap1.state, .idle)
        XCTAssertGreaterThanOrEqual(snap1.totalMs, 10)

        // Idempotent — second turnEnd should not crash.
        await emitter.apply(.turnEnd(turnId: turnId, stopReason: .endTurn))
        let snap2 = await emitter._currentSnapshot()
        XCTAssertEqual(snap2.state, .idle)
    }

    // DE7: The emitter sends a snapshot on the output channel after every apply.
    func test_DE7_outputChannelReceivesSnapshots() async {
        let emitter = DevSnapshotEmitter()
        let channel = await emitter.output
        let turnId = TurnID(rawValue: "t6")

        // Spawn a drainer that collects the first 3 snapshots.
        let drain = Task { () -> [DevSnapshot] in
            var out: [DevSnapshot] = []
            for await snap in channel {
                out.append(snap)
                if out.count == 3 { break }
            }
            return out
        }

        await emitter.apply(.stateChange(.thinking))
        await emitter.apply(.tokenDelta(turnId: turnId, text: "a"))
        await emitter.apply(.tokenDelta(turnId: turnId, text: "b"))

        let snaps = await drain.value
        XCTAssertEqual(snaps.count, 3)
        XCTAssertEqual(snaps[0].state, .thinking)
    }

    // DE8: Output channel is configured with capacity 32 + .dropOldest
    // (AGENT-10 four-seam invariant).
    func test_DE8_channelTopologyAgent10() async {
        let emitter = DevSnapshotEmitter()
        let channel = await emitter.output
        XCTAssertEqual(channel.capacity, 32)
        if case .dropOldest = channel.policy {
            // ok
        } else {
            XCTFail("expected .dropOldest policy, got \(channel.policy)")
        }
    }
}
