// ConfirmationBroker.swift
//
// FSM that gates AppleScript (and any future requiresConfirmation tool) on
// explicit user approval. Plan 05-05 Task 1.
//
// Closes:
//   - MCP-09 (broker FSM, first-write-wins on .approve / .deny / .timeout / .barge)
//   - AGENT-11 (60-second timeout-as-deny via Task.sleep)
//
// Concurrency model:
//   - Public actor — the serial executor IS the synchronization primitive.
//     No locks, no atomics. Every method runs serialized on the actor's
//     executor; concurrent `response(id:outcome:)` calls from the presenter
//     button handlers + the timer task can race the actor entry, but only
//     ONE wins because the `resolved` flag lives behind the actor barrier.
//   - The injected `presenter` is `Sendable` and conforms to
//     `ConfirmationPresenting`. The broker fires-and-forgets the show /
//     dismiss calls into a Task so the broker's actor isolation isn't
//     blocked by presenter work.
//
// Test injection:
//   - `timeoutSeconds: TimeInterval = 60` defaults to AGENT-11's spec but
//     accepts sub-second values for unit tests so they don't have to wait
//     a real minute. ConfirmationBrokerTests passes 0.05 to assert
//     `.timeout`.
//
// MCP-09 invariant (first-write-wins):
//   - `response(id:outcome:)` checks `resolved` before resuming. The first
//     call wins; subsequent calls (timer firing after presenter, or vice
//     versa, or a barge-in racing both) are silent no-ops. Tests
//     `test_lateResponse_afterApprove_isNoOp` and
//     `test_lateResponse_afterTimeout_isNoOp` regression-guard.

import Foundation

public actor ConfirmationBroker {

    /// In-flight request slot. Carries the awaiter's continuation, the
    /// timeout task that will synthesize `.timeout` if no response arrives,
    /// and a `resolved` guard that enforces MCP-09.
    private struct PendingRequest {
        let id: UUID
        let toolName: String
        let argsPreview: String
        var continuation: CheckedContinuation<ConfirmationOutcome, Never>?
        var resolved: Bool
        var timeoutTask: Task<Void, Never>?
    }

    private var pending: [UUID: PendingRequest] = [:]
    private let presenter: any ConfirmationPresenting
    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 60, presenter: any ConfirmationPresenting) {
        self.timeoutSeconds = timeoutSeconds
        self.presenter = presenter
    }

    /// Suspend the caller until the user (or timer / barge path) responds.
    /// Returns the resolved outcome. Always resumes exactly once per id.
    public func request(
        id: UUID,
        toolName: String,
        argsPreview: String
    ) async -> ConfirmationOutcome {
        return await withCheckedContinuation { continuation in
            // Fire-and-forget the presenter show. The broker doesn't await
            // the show: the user's action is what produces a response, and
            // the timer guarantees a fallback.
            let presenter = self.presenter
            Task {
                await presenter.show(id: id, toolName: toolName, argsPreview: argsPreview)
            }

            // Schedule the AGENT-11 timeout. Captured weakly so the actor
            // can deinit cleanly if the awaiter resolves first; the timer
            // task is canceled in `response(id:outcome:)`.
            //
            // WR-03 (REVIEW 05): explicit do/catch on Task.sleep so the
            // CancellationError early-returns. Previous form used
            // `try? Task.sleep` (which swallows the error) plus
            // `Task.isCancelled` check — under sub-second timeouts the
            // window between Task.sleep returning and isCancelled being
            // observed could let a cancelled timer fire .timeout. Today
            // the broker's first-write-wins guard (resolved == false)
            // saves us, but if a future contributor removes that guard
            // the broker would double-resolve. Explicit cancellation
            // handling makes intent self-evident and removes the silent
            // race.
            let timeout = self.timeoutSeconds
            let timerTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    return  // canceled — first-write-wins already resolved.
                }
                await self?.response(id: id, outcome: .timeout)
            }

            let req = PendingRequest(
                id: id,
                toolName: toolName,
                argsPreview: argsPreview,
                continuation: continuation,
                resolved: false,
                timeoutTask: timerTask
            )
            pending[id] = req
        }
    }

    /// Resolve a pending request. First write wins (MCP-09); later hops are
    /// silent no-ops and never resume the awaiter twice.
    public func response(id: UUID, outcome: ConfirmationOutcome) {
        guard var req = pending[id] else {
            // Unknown id (timer fired after the entry was already cleared,
            // or a wholly bogus call). No-op.
            return
        }

        // FIRST-WRITE-WINS guard. If we're here a second time the actor's
        // serial executor already let the first response through.
        guard req.resolved == false else { return }
        req.resolved = true

        // Cancel the still-pending timeout (idempotent — Task.cancel on a
        // finished task is a no-op).
        req.timeoutTask?.cancel()

        // Resume the awaiter EXACTLY ONCE.
        let continuation = req.continuation
        req.continuation = nil
        pending[id] = nil
        continuation?.resume(returning: outcome)

        // Fire-and-forget dismiss so the panel comes down. The broker
        // doesn't await; presentation work runs on the @MainActor side.
        let presenter = self.presenter
        Task {
            await presenter.dismiss(id: id)
        }
    }
}
