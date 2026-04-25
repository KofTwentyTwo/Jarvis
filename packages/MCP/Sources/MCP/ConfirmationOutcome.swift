// ConfirmationOutcome.swift
//
// FSM outcome enum + matching error type for the ConfirmationBroker.
// Plan 05-05 Task 1.
//
// MCP-09 invariant (the FSM resolves once): four legal transitions —
// `.approve`, `.deny`, `.timeout`, `.barge`. The broker actor's
// `response(id:outcome:)` is first-write-wins; later hops are silent
// no-ops.
//
// AGENT-11 timeout-as-deny: `.timeout` is the implementation form of
// "synthesized deny" per ROADMAP SC-3. ConfirmingToolDispatcher (Plan 05-05
// Task 3) treats `.timeout` like `.deny` for orchestrator surface but logs
// the distinction at WARNING severity to JarvisLogChannel.mcp.

import Foundation

/// Outcome of a single confirmation request.
public enum ConfirmationOutcome: Sendable, Equatable {
    case approve
    case deny
    case timeout
    case barge
}

/// Thrown by `ConfirmingToolDispatcher.dispatch(toolUse:)` on a non-approve
/// outcome. The orchestrator's existing thrown-error path translates this
/// into `.toolCardUpdate(.failed)` plus a synthesized tool_result error in
/// history (Plan 04-04). From history's perspective `.timedOut` and
/// `.denied` are equivalent; `.barged` carries the user-cancellation
/// distinction for future replay slicing.
public enum ConfirmationError: Error, Sendable, Equatable {
    case denied
    case timedOut(after: TimeInterval)
    case barged
}

/// Presentation surface used by the broker to show the confirmation panel
/// (Plan 05-05 Task 2 — `ConfirmationPresenter`) and dismiss it on outcome.
///
/// Defined here (not in Task 2's file) so Task 1's broker implementation
/// can compile + test against a mock without pulling AppKit. Production
/// `ConfirmationPresenter` and the cycle-breaking `ConfirmationPresenterHolder`
/// (App/MCP/MCPRuntimeWiring.swift) both conform.
public protocol ConfirmationPresenting: Sendable {
    /// Show the approve/deny panel for the given pending request.
    /// Implementations hop to MainActor internally if needed.
    func show(id: UUID, toolName: String, argsPreview: String) async

    /// Dismiss the panel for the given id. Called exactly once per
    /// resolved request (broker invariant).
    func dismiss(id: UUID) async
}
