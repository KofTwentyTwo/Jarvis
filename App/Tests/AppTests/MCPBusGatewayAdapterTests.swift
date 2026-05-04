// MCPBusGatewayAdapterTests.swift
//
// BLOCKER-INT-1 closure proof: assert that `MCPBusGatewayAdapter` (the
// real BusGateway production code; replaces NoopBusGateway at
// AppDelegate.swift:503) forwards tool-call events through `OutboundBatcher`
// to its `Sink` so the HUD's chat-panel ToolCallCard receives the wire
// `BusOutbound.toolCallStart` / `.toolCallEnd` envelopes the JS-side
// reconciler in `webview/packages/hud/src/bus/client.ts` consumes.
//
// The previous `NoopBusGateway` was the canonical "test mock and prod
// stub diverge in the same direction" pattern called out in
// `.planning/audit-2026-05-03/tests-audit.md` §6: SpyBus in
// MCPRuntimeWiringTests.swift counted invocations + production used
// NoopBusGateway with empty bodies. Both satisfied the protocol; only
// the latter shipped — and silently dropped every tool-call card.
//
// These tests assert the production-side behavior of the replacement:
// the events DO reach the sink, with stable ids that allow the HUD to
// reconcile start / update / end by id.

import XCTest
import Foundation
import Bus
@testable import Jarvis  // MCPBusGatewayAdapter is internal to the App target

@MainActor
final class MCPBusGatewayAdapterTests: XCTestCase {

    /// Recording `OutboundBatcher.Sink` — captures every `BusOutbound`
    /// envelope that reaches the JS-call boundary. `@MainActor` matches
    /// the protocol's `sendRaw` isolation.
    final class RecordingSink: OutboundBatcher.Sink, @unchecked Sendable {
        var sent: [BusOutbound] = []
        @MainActor func sendRaw(_ msg: BusOutbound) async throws {
            sent.append(msg)
        }
    }

    // MARK: - Stable id derivation

    /// `stableUUID(from:)` is deterministic — same input string always
    /// produces the same UUID. Load-bearing for HUD reconciliation:
    /// `emitToolCallStart(id="toolu_X")` followed by
    /// `emitToolCallEnd(id="toolu_X")` MUST produce matching UUIDs so
    /// the JS-side `upsertToolCall` patches the existing card rather
    /// than orphaning the start emission.
    func test_stableUUID_isDeterministic() {
        let a = MCPBusGatewayAdapter.stableUUID(from: "toolu_01ABCDEFGH")
        let b = MCPBusGatewayAdapter.stableUUID(from: "toolu_01ABCDEFGH")
        XCTAssertEqual(a, b, "same input must produce same UUID across calls")
    }

    /// Distinct dispatcher String ids must produce distinct UUIDs so two
    /// concurrent tool calls don't collide in the HUD.
    func test_stableUUID_distinguishesDifferentIds() {
        let a = MCPBusGatewayAdapter.stableUUID(from: "toolu_01ABC")
        let b = MCPBusGatewayAdapter.stableUUID(from: "toolu_01XYZ")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Event flow: gateway → batcher → sink

    /// `emitToolCallStart` produces exactly one `.toolCallStart` envelope at
    /// the sink, carrying the deterministic UUID + the name + argsPreview.
    /// This is the base case BLOCKER-INT-1 was breaking: NoopBusGateway
    /// dropped this entirely.
    func test_emitToolCallStart_reachesSink() async throws {
        let sink = RecordingSink()
        let batcher = OutboundBatcher(sink: sink, windowMillis: 5)
        let adapter = MCPBusGatewayAdapter(resolveBatcher: { batcher })

        await adapter.emitToolCallStart(
            toolUseId: "toolu_01TEST",
            name: "run_applescript",
            argsPreview: "{\"awaitingApproval\":true}"
        )

        XCTAssertEqual(sink.sent.count, 1, "exactly one envelope at the sink")
        guard case let .toolCallStart(id, name, argsPreview) = sink.sent[0] else {
            XCTFail("expected .toolCallStart, got \(sink.sent[0])")
            return
        }
        XCTAssertEqual(id, MCPBusGatewayAdapter.stableUUID(from: "toolu_01TEST"))
        XCTAssertEqual(name, "run_applescript")
        XCTAssertEqual(argsPreview, "{\"awaitingApproval\":true}")
    }

    /// `emitToolCallEnd` produces a `.toolCallEnd` whose UUID matches the
    /// UUID `emitToolCallStart` would have produced for the same dispatcher
    /// String id. HUD reconciliation depends on this equality.
    func test_emitToolCallEnd_idMatchesStart() async throws {
        let sink = RecordingSink()
        let batcher = OutboundBatcher(sink: sink, windowMillis: 5)
        let adapter = MCPBusGatewayAdapter(resolveBatcher: { batcher })

        await adapter.emitToolCallStart(toolUseId: "toolu_01ID", name: "get_time", argsPreview: "{}")
        await adapter.emitToolCallEnd(
            toolUseId: "toolu_01ID",
            name: "get_time",
            ok: true,
            previewOrError: "\"2026-05-04T00:00:00Z\""
        )

        XCTAssertEqual(sink.sent.count, 2)
        guard
            case let .toolCallStart(startId, _, _) = sink.sent[0],
            case let .toolCallEnd(endId, ok, previewOrError) = sink.sent[1]
        else {
            XCTFail("expected toolCallStart followed by toolCallEnd")
            return
        }
        XCTAssertEqual(startId, endId, "HUD reconciliation requires matching id across start/end")
        XCTAssertTrue(ok)
        XCTAssertEqual(previewOrError, "\"2026-05-04T00:00:00Z\"")
    }

    /// `updateArgsPreview` re-emits a `.toolCallStart` carrying the
    /// post-approval sanitized args. The HUD's `upsertToolCall` patches
    /// the existing card by id (see streaming.test.tsx D5 / D5b in
    /// `webview/packages/hud/`), transitioning awaiting-approval → running
    /// while the args render the real post-approval payload.
    func test_updateArgsPreview_reEmitsStartWithSameId() async throws {
        let sink = RecordingSink()
        let batcher = OutboundBatcher(sink: sink, windowMillis: 5)
        let adapter = MCPBusGatewayAdapter(resolveBatcher: { batcher })

        await adapter.emitToolCallStart(
            toolUseId: "toolu_01APPLE",
            name: "run_applescript",
            argsPreview: "{\"awaitingApproval\":true}"
        )
        await adapter.updateArgsPreview(
            toolUseId: "toolu_01APPLE",
            name: "run_applescript",
            argsPreview: "{\"script\":\"return 1\"}"
        )

        XCTAssertEqual(sink.sent.count, 2)
        guard
            case let .toolCallStart(id1, _, args1) = sink.sent[0],
            case let .toolCallStart(id2, _, args2) = sink.sent[1]
        else {
            XCTFail("expected two .toolCallStart emissions")
            return
        }
        XCTAssertEqual(id1, id2, "update must carry same id so HUD patches the existing card")
        XCTAssertEqual(args1, "{\"awaitingApproval\":true}")
        XCTAssertEqual(args2, "{\"script\":\"return 1\"}")
    }

    /// Late binding: when the resolver returns `nil` (batcher not yet
    /// constructed in installAgent step 13), the adapter drops the
    /// emission silently rather than crashing. The audit-trail
    /// correlation lives in `ReplayingToolResultObserver` (separate path).
    func test_nilBatcher_dropsEventSilently() async {
        let adapter = MCPBusGatewayAdapter(resolveBatcher: { nil })
        // No assertion fails — the call must not throw or trap.
        await adapter.emitToolCallStart(toolUseId: "toolu_01EARLY", name: "x", argsPreview: "{}")
        await adapter.updateArgsPreview(toolUseId: "toolu_01EARLY", name: "x", argsPreview: "{}")
        await adapter.emitToolCallEnd(
            toolUseId: "toolu_01EARLY",
            name: "x",
            ok: false,
            previewOrError: "early"
        )
    }
}
