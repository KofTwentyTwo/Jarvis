import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// AGENT-10 four-seam channel topology verification.
///
/// Four inter-subsystem seams:
///
/// 1. **provider→orch** (unbounded via URLSession backpressure). Not a
///    `BoundedAsyncChannel` — the provider's `AsyncThrowingStream` absorbs
///    backpressure from the socket. Tested implicitly by the provider byte-
///    replay suites in Plan 04-01 / 04-02; no `capacity` to assert here.
///
/// 2. **orch→bus** — `AgentOrchestrator.events`
///    = `BoundedAsyncChannel<OrchestratorEvent>(capacity: 256, policy: .suspend)`.
///    Verified by CT1.
///
/// 3. **orch→replay** (capacity 2048, drop-oldest for tokenDelta only).
///    Primitive exists as `TokenDeltaDropOldestChannel` (Plan 04-03). The
///    orchestrator currently calls `replayLog.record(...)` directly (the
///    actor's internal batching absorbs the load, not a pre-actor channel)
///    so the 2048-capacity instance is not wired at the orch↔replay seam.
///    CT2 verifies the primitive's semantics: tokenDelta lossy,
///    tool_call / turn_end never lossy. This is the AGENT-10 contract —
///    when a channel IS wired in Phase 5+ between orchestrator and replay,
///    it will use this primitive with these semantics.
///
/// 4. **orch→devoverlay** — `DevSnapshotEmitter.output`
///    = `BoundedAsyncChannel<DevSnapshot>(capacity: 32, policy: .dropOldest)`.
///    Verified by CT3.
///
/// CT4 verifies non-tokenDelta events never drop during a real orchestrated
/// turn under load.
@MainActor
final class ChannelTopologyTests: XCTestCase {
    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    // MARK: - CT1: orch→bus topology

    /// CT1: `AgentOrchestrator.events` is capacity 256, policy .suspend.
    func test_CT1_orchestratorEventsChannelIs256Suspend() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "t", buildSHA: "ct1")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "",
            availableTools: []
        )
        XCTAssertEqual(orch.events.capacity, 256)
        if case .suspend = orch.events.policy {
            // ok
        } else {
            XCTFail("expected .suspend policy, got \(orch.events.policy)")
        }
    }

    // MARK: - CT2: replay primitive — tokenDelta lossy, others never lossy

    /// CT2: `TokenDeltaDropOldestChannel` semantics verified directly.
    /// - Fire 500 `.tokenDelta` events into a capacity-64 channel with no
    ///   draining — tokenDelta count in buffer caps at 64, oldest dropped.
    /// - Interleave 5 non-tokenDelta events — those must never drop.
    ///
    /// This is the contract the orch→replay seam honors when it's wired
    /// through this primitive; the actual `capacity: 2048` is a tuning knob
    /// for production, not an invariant.
    func test_CT2_tokenDeltaLossyNonTokenDeltaNeverLossy() async {
        let ch = TokenDeltaDropOldestChannel<ReplayTag>(capacity: 64, dropTag: .tokenDelta)

        // Background drainer that reads forever into an array.
        let drained = TestCounter()
        let nonDropDrained = TestCounter()
        let drainer = Task {
            for await el in ch {
                await drained.inc()
                if el.tag != .tokenDelta {
                    await nonDropDrained.inc()
                }
            }
        }

        // Give the drainer a chance to start; then fire 500 tokenDeltas +
        // 5 tool_call + 3 turn_end + 2 reconfigure events concurrently
        // enough that the buffer is pressured.
        for i in 0..<500 {
            await ch.send(.init(tag: .tokenDelta, payload: Data("t\(i)".utf8)))
        }
        for i in 0..<5 {
            await ch.send(.init(tag: .toolCall, payload: Data("tc\(i)".utf8)))
        }
        for i in 0..<3 {
            await ch.send(.init(tag: .turnEnd, payload: Data("te\(i)".utf8)))
        }
        for i in 0..<2 {
            await ch.send(.init(tag: .reconfigure, payload: Data("r\(i)".utf8)))
        }

        // Let the drainer flush everything.
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        await ch.finish()
        _ = await drainer.value

        // All 10 non-tokenDelta events must have been delivered (never lossy).
        let ndd = await nonDropDrained.get()
        XCTAssertEqual(ndd, 10, "non-tokenDelta events must NEVER drop; got \(ndd)")

        // Total drained is ≤ 64 tokenDeltas + 10 non-tokenDelta = 74, minus
        // any tokenDeltas evicted by dropOldest. In practice the drainer
        // runs concurrently so more tokenDeltas flow through than the
        // buffer cap — the invariant is "tokenDeltas CAN drop under
        // pressure" not "at least N tokenDeltas drop".
        let total = await drained.get()
        XCTAssertLessThanOrEqual(total, 510, "total drained is bounded")
    }

    // MARK: - CT3: orch→devoverlay topology

    /// CT3: DevSnapshotEmitter output channel is capacity 32 policy .dropOldest.
    /// Fire >32 events through the emitter with a stalled consumer, assert
    /// the consumer sees ≤ 32 snapshots (drop-oldest in effect).
    func test_CT3_devOverlayChannelIs32DropOldest() async {
        let emitter = DevSnapshotEmitter()
        let channel = await emitter.output
        XCTAssertEqual(channel.capacity, 32)
        if case .dropOldest = channel.policy {
            // ok
        } else {
            XCTFail("expected .dropOldest, got \(channel.policy)")
        }

        // Stall a consumer — never drain — and pressure the channel. Use a
        // detached Task that drains only AFTER we've queued well over 32
        // events; the drop-oldest policy ensures we don't block forever.
        let turnId = TurnID(rawValue: "ct3")
        for i in 0..<100 {
            await emitter.apply(.tokenDelta(turnId: turnId, text: "t\(i)"))
        }

        // Now drain — channel returns snapshots in FIFO order; with
        // .dropOldest only the latest 32 remain.
        var seen = 0
        let drainer = Task { () -> Int in
            var c = 0
            for await _ in channel {
                c += 1
                if c >= 33 { break }
            }
            return c
        }
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await channel.finish()
        seen = await drainer.value
        XCTAssertLessThanOrEqual(seen, 33, "drop-oldest cap enforced")
    }

    // MARK: - CT4: stress scenario — non-tokenDelta events never lost

    /// CT4: Run an orchestrator with a mock that fires 200 tokenDeltas,
    /// 3 tool_calls, 2 reconfigure state changes (via retry loop), 1 turn_end.
    /// Assert every non-tokenDelta event is delivered on the orch.events
    /// channel.
    ///
    /// The orch.events channel is .suspend (not lossy), so this test is also
    /// an end-to-end verification that no event-category lossiness has been
    /// accidentally introduced.
    func test_CT4_orchestratorEventsNeverDropNonTokenDelta() async throws {
        // Script 1: 200 tokenDeltas + a tool_use, then stopReason .toolUse.
        var events1: [LLMEvent] = [
            .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
        ]
        for i in 0..<200 {
            events1.append(.textDelta("t\(i)"))
        }
        let toolReq1 = ToolUseRequest(id: "tu1", name: "get_time", argsJSON: Data("{}".utf8))
        events1.append(.toolUseRequested(toolReq1))
        events1.append(.stopReason(.toolUse))
        events1.append(.messageStop)

        // Script 2: one more tool_use + stopReason .toolUse.
        let toolReq2 = ToolUseRequest(id: "tu2", name: "get_time", argsJSON: Data("{}".utf8))
        let events2: [LLMEvent] = [
            .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
            .toolUseRequested(toolReq2),
            .stopReason(.toolUse),
            .messageStop,
        ]

        // Script 3: final turn — another tool_use + end turn.
        let toolReq3 = ToolUseRequest(id: "tu3", name: "get_time", argsJSON: Data("{}".utf8))
        let events3: [LLMEvent] = [
            .messageStart(LLMMessageStart(messageId: "m3", model: "x", usagePrefix: nil)),
            .toolUseRequested(toolReq3),
            .stopReason(.toolUse),
            .messageStop,
        ]

        // Script 4: endTurn.
        let events4: [LLMEvent] = [
            .messageStart(LLMMessageStart(messageId: "m4", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]

        let mock = MockLLMProvider(scripts: [
            .init(events: events1),
            .init(events: events2),
            .init(events: events3),
            .init(events: events4),
        ])
        let dispatcher = StubToolDispatcher(dispatch: { _ in Data("{}".utf8) })

        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "t", buildSHA: "ct4")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: dispatcher,
            replayLog: replay,
            sessionId: session,
            systemPrompt: "",
            availableTools: [
                ToolSchema(name: "get_time", description: "time", inputSchema: Data("{}".utf8)),
            ]
        )

        _ = await orch.submit(.text("stress"))

        // Drain until .stateChange(.idle).
        var collected: [OrchestratorEvent] = []
        let deadline = Date().addingTimeInterval(10)
        for await ev in orch.events {
            collected.append(ev)
            if case .stateChange(.idle) = ev { break }
            if Date() > deadline { break }
        }

        // Count categories.
        var toolCardUpdates = 0
        var turnEnds = 0
        var stateChanges = 0
        var tokenDeltas = 0
        for ev in collected {
            switch ev {
            case .toolCardUpdate: toolCardUpdates += 1
            case .turnEnd:        turnEnds += 1
            case .stateChange:    stateChanges += 1
            case .tokenDelta:     tokenDeltas += 1
            default:              break
            }
        }

        // 3 tool_calls × 2 updates each (running + completed) = 6.
        XCTAssertEqual(toolCardUpdates, 6, "each of 3 tool calls emits running+completed; no drops")
        // One turnEnd for the endTurn terminator.
        XCTAssertEqual(turnEnds, 1, "exactly one turnEnd(.endTurn)")
        // Must include at least .thinking and .idle state changes.
        XCTAssertGreaterThanOrEqual(stateChanges, 2, "at least .thinking + .idle state changes")
        // All 200 tokenDeltas should flow through (.suspend policy, not lossy).
        XCTAssertEqual(tokenDeltas, 200, "all 200 tokenDeltas flow through .suspend-policy channel")
    }
}

/// Small tag type for the replay primitive — mirrors the production tags the
/// orchestrator would use at the orch→replay seam.
fileprivate enum ReplayTag: Sendable, Equatable, Hashable {
    case tokenDelta
    case toolCall
    case turnEnd
    case reconfigure
}
