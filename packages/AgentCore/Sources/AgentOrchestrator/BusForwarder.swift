import Foundation
import AgentCore

/// BusForwarder — pure translation from `OrchestratorEvent` to JS-side
/// chat-panel lifecycle events. Lives here (AgentOrchestrator) rather than
/// in the App target because the App target's xctest harness is upstream-
/// broken on Xcode 26 (`scripts/check-app-builds.sh` is a build-only gate).
/// Keeping the logic package-local makes it unit-testable via `swift test`.
///
/// **Closes BLOCKER-INT-2 / INT-3 fully.** Producers in five orchestrator
/// subscribers (memory / transcript / devOverlay / frameAttach / voice) have
/// always existed; this is the sixth — the one that drives the visible HUD
/// chat panel. Without it, the JS-side `chatEvents` store renders an empty
/// array regardless of how many tokens the orchestrator emits.
///
/// **Translation rules:**
/// - `tokenDelta(turnId, text)` — synthesizes `turnStarted(id:)` on the
///   first emission for a fresh `turnId`, then `postToken(text)`. The JS
///   dispatcher silently drops `tokenDelta` when `currentTurnId === null`,
///   so a synthetic start MUST precede the first per-turn token.
/// - `turnEnd(turnId, stopReason)` — emits `turnEnded(id:terminator:)` with
///   `stopReason` collapsed via `terminator(for:)`. Synthesizes a missing
///   `turnStarted` first if the orchestrator emits a turnEnd without any
///   prior tokenDelta (e.g. immediate refusal / tool-only turn).
/// - `error(_, error)` — emits `submitRejected(reason:)` with a description
///   of the error. The JS dispatcher renders submitRejected as an inline
///   error event in the chat panel — without this branch, mid-stream
///   failures (401 / network drop / streamTruncated) leave the panel
///   silent and the user has no idea their turn died.
/// - All other cases (`stateChange`, `thinkingDelta`, `toolCardUpdate`,
///   `usage`) — ignored. They have dedicated subscribers elsewhere.
public enum BusForwarder {
    /// Coarsened JS-protocol terminator. Mirrors `Bus.TurnTerminator` but
    /// is declared here so this file does NOT depend on the Bus package
    /// (App target translates this enum into the wire form). Adding a new
    /// case requires updating `terminator(for:)` to keep the mapping total.
    public enum Terminator: String, Sendable, CaseIterable {
        case completed
        case cancelled
        case errored
        case superseded
    }

    /// `StopReason → Terminator` table. The JS protocol classifies turn
    /// outcomes more coarsely than the orchestrator: `endTurn`, `toolUse`,
    /// `maxTokens` collapse to `.completed`; `refusal` and `streamTruncated`
    /// collapse to `.errored`. `cancelled` / `superseded` are reachable via
    /// cancel-and-submit / barge-in flows the orchestrator does not yet emit
    /// as distinct `StopReason` cases — extend the switch when they do.
    public static func terminator(for stopReason: StopReason) -> Terminator {
        switch stopReason {
        case .endTurn, .toolUse, .maxTokens:
            return .completed
        case .refusal, .streamTruncated:
            return .errored
        }
    }

    /// Drive a `BusForwarderSink` from an `AsyncStream<OrchestratorEvent>`.
    /// Returns when the stream finishes or the surrounding Task is cancelled.
    /// The local `lastEmittedTurnId` state lives only on the calling task —
    /// no actor isolation needed (the sink itself is the isolation boundary).
    public static func drain<S>(
        events: S,
        sink: any BusForwarderSink
    ) async where S: AsyncSequence & Sendable, S.Element == OrchestratorEvent {
        var lastEmittedTurnId: TurnID?
        do {
            for try await event in events {
                if Task.isCancelled { break }
                switch event {
                case let .tokenDelta(turnId, text):
                    if lastEmittedTurnId != turnId,
                       let uuid = UUID(uuidString: turnId.rawValue) {
                        await sink.sendTurnStarted(id: uuid)
                        lastEmittedTurnId = turnId
                    }
                    await sink.postToken(text)

                case let .turnEnd(turnId, stopReason):
                    if let uuid = UUID(uuidString: turnId.rawValue) {
                        if lastEmittedTurnId != turnId {
                            await sink.sendTurnStarted(id: uuid)
                        }
                        await sink.sendTurnEnded(
                            id: uuid,
                            terminator: terminator(for: stopReason)
                        )
                    }
                    lastEmittedTurnId = nil

                case let .error(_, error):
                    let reason = "Turn failed: \(String(describing: error))"
                    await sink.sendSubmitRejected(reason: reason)

                default:
                    break
                }
            }
        } catch {
            // AsyncSequence closed via thrown error — treat as cancellation.
            // The sink stays registered; a subsequent `drain` call may resume
            // forwarding from a fresh subscription.
        }
    }
}

/// Sink protocol consumed by `BusForwarder.drain`. The App target provides
/// the production conformer wrapping `OutboundBatcher`; tests use a
/// recording fake. All methods are `async` because the production sink
/// dispatches across the OutboundBatcher actor boundary.
public protocol BusForwarderSink: Sendable {
    func postToken(_ chunk: String) async
    func sendTurnStarted(id: UUID) async
    func sendTurnEnded(id: UUID, terminator: BusForwarder.Terminator) async
    func sendSubmitRejected(reason: String) async
}
