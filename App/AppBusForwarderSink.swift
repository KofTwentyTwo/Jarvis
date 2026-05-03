import Foundation
import AgentOrchestrator   // BusForwarder, BusForwarderSink
import Bus                 // OutboundBatcher, BusOutbound, TurnTerminator

/// App-side adapter that wires `BusForwarder` (pure logic, lives in
/// AgentOrchestrator for unit-testability) to `OutboundBatcher` (the
/// transport-coalescing actor in the Bus package). The sink's only job is
/// translating the protocol-agnostic `BusForwarder.Terminator` enum into
/// the wire-format `Bus.TurnTerminator` and dispatching across the batcher
/// actor boundary.
///
/// This split is the lesson from the 2026-05-03 INT-3 audit: the bus
/// forwarder lived inline in `AppDelegate.swift` previously, which made it
/// untestable because the App target's xctest harness is upstream-broken
/// on Xcode 26. Every branch now has unit coverage in
/// `BusForwarderTests.swift`; this file is the (small, hard-to-misread)
/// glue layer.
struct AppBusForwarderSink: BusForwarderSink {
    let batcher: OutboundBatcher

    func postToken(_ chunk: String) async {
        await batcher.postToken(chunk)
    }

    func sendTurnStarted(id: UUID) async {
        try? await batcher.flushAndSend(.turnStarted(id: id))
    }

    func sendTurnEnded(id: UUID, terminator: BusForwarder.Terminator) async {
        try? await batcher.flushAndSend(
            .turnEnded(id: id, terminator: Self.wireTerminator(from: terminator))
        )
    }

    func sendSubmitRejected(reason: String) async {
        try? await batcher.flushAndSend(.submitRejected(reason: reason))
    }

    /// 1:1 mapping from `BusForwarder.Terminator` (protocol-agnostic, lives
    /// in AgentCore) to `Bus.TurnTerminator` (wire format). Both enums must
    /// stay in sync; the cases are deliberately identical so each call site
    /// either fans out trivially or fails fast at compile time when one
    /// side adds a case.
    static func wireTerminator(from t: BusForwarder.Terminator) -> TurnTerminator {
        switch t {
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .errored: return .errored
        case .superseded: return .superseded
        }
    }
}
