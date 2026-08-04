import XCTest
import AgentCore
import Config
@testable import AgentOrchestrator

/// Coverage for `BusForwarder.drain` — the .bus subscriber's translation
/// from `OrchestratorEvent` to JS-side chat-panel lifecycle events.
///
/// Closes the test gap that v0.12.0 audit #2 (this session) revealed: the
/// previous .bus subscriber was inline in `App/AppDelegate.swift` and could
/// not be unit-tested because the App target's xctest harness is upstream-
/// broken on Xcode 26. After extracting to AgentOrchestrator, every branch
/// of the translation rule is now exercisable via `swift test`.
@MainActor
final class BusForwarderTests: XCTestCase {

    // MARK: - Recording sink

    /// Actor-isolated recorder. We snapshot fields via the `read*()` methods
    /// to avoid Sendable trouble crossing into MainActor test methods.
    actor RecordingSink: BusForwarderSink {
        private(set) var tokens: [String] = []
        private(set) var turnStarts: [UUID] = []
        private(set) var turnEnds: [(UUID, BusForwarder.Terminator)] = []
        private(set) var rejections: [String] = []
        private(set) var escalations: [EscalationDecision] = []

        func postToken(_ chunk: String) async { tokens.append(chunk) }
        func sendTurnStarted(id: UUID) async { turnStarts.append(id) }
        func sendTurnEnded(id: UUID, terminator: BusForwarder.Terminator) async {
            turnEnds.append((id, terminator))
        }
        func sendSubmitRejected(reason: String) async { rejections.append(reason) }
        func sendEscalated(decision: EscalationDecision) async {
            escalations.append(decision)
        }

        func snapshot() -> (
            tokens: [String],
            turnStarts: [UUID],
            turnEnds: [(UUID, BusForwarder.Terminator)],
            rejections: [String],
            escalations: [EscalationDecision]
        ) {
            (tokens, turnStarts, turnEnds, rejections, escalations)
        }
    }

    private func makeStream(_ events: [OrchestratorEvent]) -> AsyncStream<OrchestratorEvent> {
        AsyncStream { cont in
            for e in events { cont.yield(e) }
            cont.finish()
        }
    }

    private func uuidString() -> String { UUID().uuidString }

    // MARK: - Terminator mapping (BF-T1..T5)

    func testTerminator_endTurn_isCompleted() {
        XCTAssertEqual(BusForwarder.terminator(for: .endTurn), .completed)
    }

    func testTerminator_toolUse_isCompleted() {
        XCTAssertEqual(BusForwarder.terminator(for: .toolUse), .completed)
    }

    func testTerminator_maxTokens_isCompleted() {
        XCTAssertEqual(BusForwarder.terminator(for: .maxTokens), .completed)
    }

    func testTerminator_refusal_isErrored() {
        XCTAssertEqual(BusForwarder.terminator(for: .refusal), .errored)
    }

    func testTerminator_streamTruncated_isErrored() {
        XCTAssertEqual(BusForwarder.terminator(for: .streamTruncated), .errored)
    }

    // MARK: - tokenDelta forwarding (BF-D1..D3)

    func testDrain_tokenDelta_synthesizesTurnStartThenForwardsToken() async {
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .tokenDelta(turnId: turnId, text: "hi")
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.turnStarts.count, 1)
        XCTAssertEqual(snap.turnStarts.first?.uuidString, turnId.rawValue)
        XCTAssertEqual(snap.tokens, ["hi"])
        XCTAssertTrue(snap.turnEnds.isEmpty)
    }

    func testDrain_repeatedTokenDelta_sameTurn_noDuplicateStart() async {
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .tokenDelta(turnId: turnId, text: "a"),
            .tokenDelta(turnId: turnId, text: "b"),
            .tokenDelta(turnId: turnId, text: "c"),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.turnStarts.count, 1, "turnStarted must be synthesized exactly once per turn id")
        XCTAssertEqual(snap.tokens, ["a", "b", "c"])
    }

    func testDrain_tokenDelta_acrossTwoTurns_emitsTwoStarts() async {
        let sink = RecordingSink()
        let t1 = TurnID(rawValue: uuidString())
        let t2 = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .tokenDelta(turnId: t1, text: "x"),
            .turnEnd(turnId: t1, stopReason: .endTurn),
            .tokenDelta(turnId: t2, text: "y"),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.turnStarts.count, 2)
        XCTAssertEqual(snap.turnStarts.map(\.uuidString), [t1.rawValue, t2.rawValue])
        XCTAssertEqual(snap.tokens, ["x", "y"])
        XCTAssertEqual(snap.turnEnds.count, 1)
    }

    // MARK: - turnEnd forwarding (BF-E1..E4)

    func testDrain_turnEnd_afterTokens_emitsEndedWithMappedTerminator() async {
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .tokenDelta(turnId: turnId, text: "hi"),
            .turnEnd(turnId: turnId, stopReason: .endTurn),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.turnEnds.count, 1)
        XCTAssertEqual(snap.turnEnds.first?.0.uuidString, turnId.rawValue)
        XCTAssertEqual(snap.turnEnds.first?.1, .completed)
    }

    func testDrain_turnEnd_withoutPriorToken_synthesizesStart() async {
        // Reachable when the orchestrator emits .turnEnd for a tool-only or
        // immediate-refusal turn without ever emitting a .tokenDelta. JS-side
        // would otherwise see endTurn before any beginTurn.
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .turnEnd(turnId: turnId, stopReason: .refusal),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.turnStarts.count, 1, "turnStarted must be synthesized before a bare turnEnd")
        XCTAssertEqual(snap.turnEnds.count, 1)
        XCTAssertEqual(snap.turnEnds.first?.1, .errored, "refusal maps to errored")
    }

    func testDrain_turnEnd_streamTruncated_isErrored() async {
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .turnEnd(turnId: turnId, stopReason: .streamTruncated),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.turnEnds.first?.1, .errored)
    }

    func testDrain_turnEnd_resetsTurnIdState_soNextTokenDeltaSynthesizesStart() async {
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .tokenDelta(turnId: turnId, text: "a"),
            .turnEnd(turnId: turnId, stopReason: .endTurn),
            // Same turnId reused (would never happen in production — turn ids
            // are fresh — but exercises the state reset logic deterministically).
            .tokenDelta(turnId: turnId, text: "b"),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.turnStarts.count, 2, "after turnEnd, the next tokenDelta must re-synthesize start")
        XCTAssertEqual(snap.tokens, ["a", "b"])
    }

    // MARK: - .error forwarding (BF-X1..X2)

    func testDrain_error_emitsSubmitRejectedWithReason() async {
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .error(turnId: turnId, error: .streamTruncatedFinal),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.rejections.count, 1)
        XCTAssertTrue(
            snap.rejections.first?.contains("Turn failed:") == true,
            "rejection reason must be prefixed so the user understands the chat-panel toast"
        )
        XCTAssertTrue(
            snap.rejections.first?.contains("streamTruncatedFinal") == true,
            "rejection reason must include the underlying provider error"
        )
    }

    func testDrain_error_doesNotEmitTurnStartedOrEnded() async {
        // .error is a runtime failure surfacing via the submitRejected channel
        // (free-form string body). We must NOT also emit turnStarted/turnEnded
        // because the orchestrator's own .turnEnd (if any) handles lifecycle.
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .error(turnId: turnId, error: .transport(description: "boom")),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertTrue(snap.turnStarts.isEmpty)
        XCTAssertTrue(snap.turnEnds.isEmpty)
        XCTAssertEqual(snap.rejections.count, 1)
    }

    // MARK: - Ignored events (BF-I1)

    func testDrain_ignoresStateChangeAndThinkingAndUsageAndToolCard() async {
        let sink = RecordingSink()
        let turnId = TurnID(rawValue: uuidString())
        let stream = makeStream([
            .stateChange(.thinking),
            .thinkingDelta(turnId: turnId, text: "..."),
            .usage(turnId: turnId, usage: .zero),
            .toolCardUpdate(ToolCardUpdate(
                turnId: turnId,
                toolUseId: "tu_1",
                toolName: "noop",
                phase: .running,
                resultPreview: nil,
                error: nil
            )),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertTrue(snap.tokens.isEmpty)
        XCTAssertTrue(snap.turnStarts.isEmpty)
        XCTAssertTrue(snap.turnEnds.isEmpty)
        XCTAssertTrue(snap.rejections.isEmpty)
    }

    // MARK: - Escalation forwarding (BF-ESC1..2)

    /// Local-first LLM routing Task 7 — `.escalated` must surface the
    /// decision to the sink so the App-side adapter can translate to
    /// `BusOutbound.escalated` and the HUD can render its badge.
    func testDrain_escalated_emitsSendEscalatedWithMatchingDecision() async {
        let sink = RecordingSink()
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let decision = EscalationDecision(
            from: .ollama,
            to: .anthropic,
            reason: .malformedToolCall,
            firedAt: firedAt
        )
        let stream = makeStream([
            .escalated(decision)
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.escalations.count, 1)
        XCTAssertEqual(snap.escalations.first, decision)
        XCTAssertTrue(snap.tokens.isEmpty)
        XCTAssertTrue(snap.turnStarts.isEmpty)
        XCTAssertTrue(snap.turnEnds.isEmpty)
        XCTAssertTrue(snap.rejections.isEmpty)
    }

    /// `.escalated` does NOT terminate the turn — the orchestrator continues
    /// streaming on the next provider. The forwarder must not synthesize a
    /// turnStarted/turnEnded pair on top of the escalation event.
    func testDrain_escalated_doesNotEmitTurnLifecycleEvents() async {
        let sink = RecordingSink()
        let decision = EscalationDecision(
            from: .ollama,
            to: .anthropic,
            reason: .connectionFailure,
            firedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let stream = makeStream([
            .escalated(decision)
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.escalations.count, 1)
        XCTAssertTrue(snap.turnStarts.isEmpty)
        XCTAssertTrue(snap.turnEnds.isEmpty)
    }

    // MARK: - Malformed turn id guard (BF-G1)

    func testDrain_tokenDelta_withNonUUIDTurnId_doesNotCrashOrEmitStart() async {
        // TurnID rawValue is documented as a UUID string, but a malformed id
        // (e.g. corrupted state, manual construction) must not crash the
        // forwarder. The protocol's `turnStarted(id: UUID)` requires a real
        // UUID — without one, we skip the start AND skip the token rather
        // than emit an inconsistent pair.
        let sink = RecordingSink()
        let badTurnId = TurnID(rawValue: "not-a-uuid")
        let stream = makeStream([
            .tokenDelta(turnId: badTurnId, text: "x"),
        ])

        await BusForwarder.drain(events: stream, sink: sink)

        let snap = await sink.snapshot()
        XCTAssertTrue(snap.turnStarts.isEmpty)
        // Token still forwarded — the JS dispatcher will warn and drop it,
        // but Swift-side must not be the gatekeeper. Documenting current
        // behavior; revisit if we want stricter validation.
        XCTAssertEqual(snap.tokens, ["x"])
    }
}
